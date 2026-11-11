"""App Store publication shared by the unified release controller.

Archive/signing stays in the existing platform adapters. This module reconciles
Apple's asynchronous state without repeating uploads or creating duplicate reviews.
"""
import json
from pathlib import Path
import re


class Pending(Exception):
    """A durable operation is waiting on Apple; resume the same release."""


REVIEWING = {"WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE", "PENDING_DEVELOPER_RELEASE",
             "ACCEPTED", "PROCESSING_FOR_DISTRIBUTION", "PROCESSING_FOR_APP_STORE", "PENDING_CONTRACT"}
AVAILABLE = {"READY_FOR_SALE", "READY_FOR_DISTRIBUTION"}
HISTORICAL = AVAILABLE | {"REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE"}
EDITABLE = {"PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "DEVELOPER_REJECTED"}
TERMINAL_SUBMISSIONS = {"COMPLETE", "CANCELED"}


def version_state(version):
    attrs = version["attributes"]
    return attrs.get("appVersionState") or attrs.get("appStoreState")


class AppStorePublisher:
    def __init__(self, api, app_id, platform, version, build, receipt, save, listing, notes):
        self.api, self.app_id, self.platform = api, app_id, platform
        self.version, self.build = version, str(build)
        self.receipt, self.save = receipt, save
        self.listing, self.notes = listing, notes

    def patch(self, resource, identifier, attributes):
        return self.api.request(resource + "/" + identifier, "PATCH", {
            "data": {"type": resource, "id": identifier, "attributes": attributes}
        })["data"]

    def versions(self):
        return self.api.list("apps/" + self.app_id + "/appStoreVersions",
                             **{"filter[platform]": self.platform})

    def build_record(self):
        rows = self.api.list("builds", **{
            "filter[app]": self.app_id, "filter[preReleaseVersion.version]": self.version,
            "filter[preReleaseVersion.platform]": self.platform,
        })
        matches = [b for b in rows if b["attributes"]["version"] == self.build]
        if len(matches) > 1:
            raise ValueError("More than one Apple build matches this release")
        if not matches:
            raise Pending("Apple has not exposed the uploaded " + self.platform + " build yet")
        build = matches[0]
        state = build["attributes"]["processingState"]
        if state in ("INVALID", "FAILED"):
            raise ValueError("Apple rejected the uploaded binary: " + state)
        if state != "VALID":
            raise Pending(self.platform + " binary is " + state)
        if self.receipt.get("build_id") not in (None, build["id"]):
            raise ValueError("Apple build identity changed")
        if self.receipt.get("build_id") != build["id"]:
            self.receipt["build_id"] = build["id"]
            self.save()
        return build

    def submissions(self):
        rows = self.api.list("reviewSubmissions", **{
            "filter[app]": self.app_id, "filter[platform]": self.platform,
        })
        return [s for s in rows if s["attributes"]["state"] not in TERMINAL_SUBMISSIONS]

    def items(self, identifier):
        return self.api.list("reviewSubmissions/" + identifier + "/items", include="appStoreVersion")

    @staticmethod
    def item_version(item):
        return (item.get("relationships", {}).get("appStoreVersion", {}).get("data") or {}).get("id")

    def cancel(self, version_id):
        """Cancellation completion is independent of the version becoming editable."""
        for submission in self.submissions():
            items = self.items(submission["id"])
            if not any(self.item_version(i) == version_id for i in items):
                continue
            if any(self.item_version(i) != version_id for i in items):
                raise ValueError("The prior review includes other items; resolve it in App Store Connect")
            if submission["attributes"]["state"] != "CANCELING":
                self.patch("reviewSubmissions", submission["id"], {"canceled": True})
            self.receipt["prior_submission_id"] = submission["id"]
            self.save()
            raise Pending("Apple is canceling the previous " + self.platform + " submission")

    def ensure_version(self):
        versions = self.versions()
        def number(value):
            return tuple(map(int, value.split(".")))
        if any(number(v["attributes"]["versionString"]) > number(self.version) for v in versions):
            raise ValueError("A newer App Store version exists; refusing to publish an older release")
        matches = [v for v in versions if v["attributes"]["versionString"] == self.version]
        if len(matches) > 1:
            raise ValueError("Multiple App Store versions match this release")
        editable = [v for v in versions if version_state(v) not in HISTORICAL]
        if matches:
            target = matches[0]
        elif len(editable) == 1:
            target = editable[0]
        elif editable:
            raise ValueError("Multiple editable App Store versions; resolve them before releasing")
        else:
            return self.api.request("appStoreVersions", "POST", {"data": {
                "type": "appStoreVersions",
                "attributes": {"platform": self.platform, "versionString": self.version,
                               "copyright": self.listing["copyright"], "releaseType": "AFTER_APPROVAL"},
                "relationships": {"app": {"data": {"type": "apps", "id": self.app_id}}},
            }})["data"]
        attrs = target["attributes"]
        state = version_state(target)
        if state in ("REJECTED", "METADATA_REJECTED", "INVALID_BINARY"):
            raise ValueError("Apple rejected this version. Read its written issues before resubmitting")
        attached = self.api.request("appStoreVersions/" + target["id"] + "/relationships/build").get("data")
        same_build = attached and attached["id"] == self.receipt["build_id"]
        if state in REVIEWING:
            if attrs["versionString"] == self.version and same_build:
                if attrs.get("releaseType") != "AFTER_APPROVAL":
                    raise ValueError("Apple release option changed; expected automatic release after approval")
                return target
            self.cancel(target["id"])
            raise Pending("Apple has not made the previous version editable yet")
        # A canceled version can become editable before its parent is CANCELED.
        if self.receipt.get("prior_submission_id"):
            parent = self.api.request("reviewSubmissions/" + self.receipt["prior_submission_id"])["data"]
            if parent["attributes"]["state"] not in TERMINAL_SUBMISSIONS:
                raise Pending("Previous Apple review is still " + parent["attributes"]["state"])
        if state in AVAILABLE:
            if not same_build:
                raise ValueError("This App Store version is already public with a different build")
            return target
        if state not in EDITABLE:
            raise ValueError("Apple version is not editable: " + str(state))
        # Retarget an editable draft, preserving its existing screenshots/listing.
        if attrs["versionString"] != self.version:
            target = self.patch("appStoreVersions", target["id"], {
                "versionString": self.version, "releaseType": "AFTER_APPROVAL",
            })
        return target

    def configure_listing(self, version):
        vid = version["id"]
        self.patch("appStoreVersions", vid, {"releaseType": "AFTER_APPROVAL"})
        localizations = self.api.list("appStoreVersions/" + vid + "/appStoreVersionLocalizations")
        locale = self.listing["locale"]
        matches = [v for v in localizations if v["attributes"]["locale"] == locale]
        attrs = {k: self.listing[k] for k in ("description", "keywords", "supportUrl", "marketingUrl")}
        attrs["whatsNew"] = self.notes
        if matches:
            self.patch("appStoreVersionLocalizations", matches[0]["id"], attrs)
        else:
            self.api.request("appStoreVersionLocalizations", "POST", {"data": {
                "type": "appStoreVersionLocalizations", "attributes": dict(attrs, locale=locale),
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}},
            }})
        # Screenshots and privacy declarations are maintained when the product
        # changes; recreating them on every code release is not a release gate.
        detail = self.api.request("appStoreVersions/" + vid + "/appStoreReviewDetail").get("data")
        contact = {"contact" + k[0].upper() + k[1:]: value for k, value in self.listing["reviewContact"].items()}
        notes = re.sub(r"NeoAnki2 \d+\.\d+\.\d+", "NeoAnki2 " + self.version, self.listing["reviewNotes"])
        attrs = dict(contact, notes=notes, demoAccountRequired=False)
        if detail:
            self.patch("appStoreReviewDetails", detail["id"], attrs)
        else:
            self.api.request("appStoreReviewDetails", "POST", {"data": {
                "type": "appStoreReviewDetails", "attributes": attrs,
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}},
            }})

    def submit(self):
        self.build_record()
        version = self.ensure_version()
        vid, state = version["id"], version_state(version)
        self.receipt["version_id"] = vid
        if state in REVIEWING | AVAILABLE:
            self.receipt["status"] = "available" if state in AVAILABLE else "submitted"
            self.receipt["apple_state"] = state
            self.save()
            return
        # Apple can acknowledge submission before the version's own state is
        # updated. Recover that acknowledgment before trying to edit the version.
        for submission in self.submissions():
            if submission["attributes"]["state"] in ("WAITING_FOR_REVIEW", "IN_REVIEW"):
                if any(self.item_version(i) == vid for i in self.items(submission["id"])):
                    attached = self.api.request("appStoreVersions/" + vid + "/relationships/build").get("data")
                    if not attached or attached["id"] != self.receipt["build_id"]:
                        raise ValueError("Active Apple review contains a different build")
                    self.receipt.update(status="submitted", apple_state=submission["attributes"]["state"],
                                        submission_id=submission["id"])
                    self.save()
                    return
        self.configure_listing(version)
        self.api.request("appStoreVersions/" + vid + "/relationships/build", "PATCH", {
            "data": {"type": "builds", "id": self.receipt["build_id"]}
        })
        submissions = self.submissions()
        saved = self.receipt.get("submission_id")
        target, has_item = None, False
        for submission in submissions:
            items = self.items(submission["id"])
            if submission["attributes"]["state"] == "CANCELING":
                raise Pending("An earlier Apple review is still canceling")
            matching = [i for i in items if self.item_version(i) == vid]
            owned_empty = not items and submission["id"] == saved
            if not matching and not owned_empty:
                raise ValueError("Another review submission is active; refusing to create a duplicate")
            if any(self.item_version(i) != vid for i in items):
                raise ValueError("Apple review includes other items; refusing to submit unrelated content")
            if target or submission["attributes"]["state"] != "READY_FOR_REVIEW":
                raise ValueError("Resolve Apple's outstanding review items before submission")
            if any(i["attributes"]["state"] != "READY_FOR_REVIEW" for i in items):
                raise ValueError("Apple review contains a rejected, removed or accepted item")
            target, has_item = submission, bool(matching)
        if target is None:
            target = self.api.request("reviewSubmissions", "POST", {"data": {
                "type": "reviewSubmissions", "attributes": {"platform": self.platform},
                "relationships": {"app": {"data": {"type": "apps", "id": self.app_id}}},
            }})["data"]
            self.receipt["submission_id"] = target["id"]
            self.save()
        if not has_item:
            self.api.request("reviewSubmissionItems", "POST", {"data": {
                "type": "reviewSubmissionItems", "relationships": {
                    "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": target["id"]}},
                    "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}},
                },
            }})
        self.patch("reviewSubmissions", target["id"], {"submitted": True})
        confirmed = self.api.request("reviewSubmissions/" + target["id"])["data"]
        if confirmed["attributes"]["state"] not in ("WAITING_FOR_REVIEW", "IN_REVIEW", "COMPLETE"):
            raise Pending("Apple has not confirmed review submission yet")
        self.receipt.update(status="submitted", apple_state=confirmed["attributes"]["state"],
                            submission_id=target["id"])
        self.save()


def listing(root, platform):
    path = "Platforms/iOS/AppStore/en-US.json" if platform == "IOS" else "Packaging/AppStore/en-US.json"
    return json.loads((Path(root) / path).read_text())
