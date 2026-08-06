(function () {
  "use strict";

  document.documentElement.classList.add("js");

  var navToggle = document.querySelector(".nav-toggle");
  var navigation = document.getElementById("site-navigation");
  var navClose = document.querySelector(".sidebar-close");
  var narrowViewport = window.matchMedia("(max-width: 820px)");
  var backgroundRegions = [
    document.querySelector(".site-header"),
    document.querySelector(".page-shell main"),
    document.querySelector(".site-footer")
  ].filter(Boolean);

  function setNavigationModal(open) {
    var modalOpen = open && narrowViewport.matches;
    document.body.classList.toggle("nav-open", modalOpen);
    backgroundRegions.forEach(function (region) {
      region.inert = modalOpen;
    });

    if (modalOpen) {
      navigation.setAttribute("role", "dialog");
      navigation.setAttribute("aria-modal", "true");
      navigation.setAttribute("aria-labelledby", "sidebar-title");
    } else {
      navigation.removeAttribute("role");
      navigation.removeAttribute("aria-modal");
      navigation.removeAttribute("aria-labelledby");
    }
  }

  function syncNavigation() {
    if (!navToggle || !navigation) {
      return;
    }

    if (narrowViewport.matches) {
      var expanded = navToggle.getAttribute("aria-expanded") === "true";
      navigation.hidden = !expanded;
      setNavigationModal(expanded);
    } else {
      navigation.hidden = false;
      navToggle.setAttribute("aria-expanded", "false");
      setNavigationModal(false);
    }
  }

  if (navToggle && navigation) {
    function closeNavigation() {
      navigation.hidden = true;
      navToggle.setAttribute("aria-expanded", "false");
      setNavigationModal(false);
      navToggle.focus();
    }

    navToggle.addEventListener("click", function () {
      var expanded = navToggle.getAttribute("aria-expanded") === "true";
      navToggle.setAttribute("aria-expanded", String(!expanded));
      navigation.hidden = expanded;
      setNavigationModal(!expanded);
      if (!expanded) {
        (navClose || navigation.querySelector("a") || navigation).focus();
      }
    });

    navigation.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && narrowViewport.matches && !navigation.hidden) {
        closeNavigation();
      }

      if (event.key === "Tab" && narrowViewport.matches && !navigation.hidden) {
        var focusable = Array.from(navigation.querySelectorAll("a[href], button:not([disabled])"));
        var first = focusable[0];
        var last = focusable[focusable.length - 1];
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first.focus();
        }
      }
    });

    if (navClose) {
      navClose.addEventListener("click", closeNavigation);
    }

    narrowViewport.addEventListener("change", syncNavigation);
    syncNavigation();
  }

  var article = document.getElementById("content");
  if (article && !article.querySelector(".local-toc")) {
    var sectionHeadings = Array.from(article.querySelectorAll("h2[id]"));
    var articleHeading = article.querySelector("h1");
    if (sectionHeadings.length >= 4 && articleHeading) {
      var toc = document.createElement("details");
      var tocSummary = document.createElement("summary");
      var tocList = document.createElement("ul");

      toc.className = "local-toc generated-toc";
      tocSummary.textContent = "On this page";
      sectionHeadings.forEach(function (heading) {
        var item = document.createElement("li");
        var link = document.createElement("a");
        link.href = "#" + heading.id;
        link.textContent = heading.textContent;
        item.append(link);
        tocList.append(item);
      });
      toc.append(tocSummary, tocList);
      articleHeading.insertAdjacentElement("afterend", toc);
    }
  }

  var skipLink = document.querySelector(".skip-link");
  var content = document.getElementById("content");
  if (skipLink && content) {
    skipLink.addEventListener("click", function () {
      window.setTimeout(function () {
        content.focus();
      }, 0);
    });
  }

  var form = document.querySelector(".site-search");
  var input = document.getElementById("site-search-input");
  var panel = document.getElementById("search-results");

  if (!form || !input || !panel) {
    return;
  }

  var status = panel.querySelector(".search-status");
  var resultList = panel.querySelector("ol");
  var searchIndex;
  var loadingIndex;

  function normalize(value) {
    return String(value || "").toLocaleLowerCase();
  }

  function searchTerms(query) {
    var aliases = {
      "anki": "apkg import compatibility",
      "backup": "restore library data",
      "flashcard": "card study",
      "migrate": "import export anki backup transfer",
      "migration": "import export anki backup transfer",
      "note": "item",
      "notes": "items",
      "picture": "image media",
      "sound": "audio media"
    };
    var terms = [query];
    if (aliases[query]) {
      terms = terms.concat(aliases[query].split(" "));
    }
    return terms;
  }

  function clearResults() {
    resultList.replaceChildren();
    status.textContent = "";
    panel.hidden = true;
  }

  function showPanel() {
    panel.hidden = false;
  }

  function resultScore(entry, query, terms) {
    var title = normalize(entry.title);
    var content = normalize(entry.content);
    var score = 0;

    if (title === query) {
      score += 100;
    } else if (title.startsWith(query)) {
      score += 60;
    } else if (title.includes(query)) {
      score += 40;
    }
    if (content.includes(query)) {
      score += 12;
    }
    terms.slice(1).forEach(function (term) {
      if (title.includes(term)) {
        score += 16;
      }
      if (content.includes(term)) {
        score += 3;
      }
    });
    return score;
  }

  function createSnippet(content, query) {
    var cleanContent = String(content || "").replace(/\s+/g, " ").trim();
    var matchAt = normalize(cleanContent).indexOf(query);
    var start = Math.max(0, matchAt - 55);
    var end = Math.min(cleanContent.length, start + 165);
    var snippet = cleanContent.slice(start, end);

    if (start > 0) {
      snippet = "…" + snippet;
    }
    if (end < cleanContent.length) {
      snippet += "…";
    }

    return snippet;
  }

  function appendRecoveryLinks() {
    var recovery = document.createElement("p");
    var firstLink = document.createElement("a");
    var separator = document.createTextNode(" or browse the ");
    var secondLink = document.createElement("a");

    recovery.className = "search-recovery";
    recovery.append(document.createTextNode("Try fewer words, start with "));
    firstLink.href = form.dataset.guideUrl;
    firstLink.textContent = "Getting started";
    recovery.append(firstLink, separator);
    secondLink.href = form.dataset.featuresUrl;
    secondLink.textContent = "task guide";
    recovery.append(secondLink, document.createTextNode("."));
    panel.append(recovery);
  }

  function renderResults(query) {
    var normalizedQuery = normalize(query.trim());
    resultList.replaceChildren();

    var oldRecovery = panel.querySelector(".search-recovery");
    if (oldRecovery) {
      oldRecovery.remove();
    }

    if (normalizedQuery.length < 2) {
      clearResults();
      return;
    }

    var terms = searchTerms(normalizedQuery);
    var matches = searchIndex.map(function (entry) {
      var searchable = normalize(entry.title + " " + entry.content);
      var matchesTerm = terms.some(function (term) {
        return searchable.includes(term);
      });
      return {
        entry: entry,
        score: matchesTerm ? resultScore(entry, normalizedQuery, terms) : 0
      };
    }).filter(function (result) {
      return result.score > 0;
    }).sort(function (left, right) {
      return right.score - left.score
        || left.entry.title.localeCompare(right.entry.title);
    }).slice(0, 8).map(function (result) {
      return result.entry;
    });

    showPanel();
    status.textContent = matches.length === 1
      ? "1 result"
      : matches.length + " results";

    matches.forEach(function (entry) {
      var item = document.createElement("li");
      var link = document.createElement("a");
      var title = document.createElement("strong");
      var snippet = document.createElement("span");

      link.href = entry.url;
      title.textContent = entry.title;
      snippet.textContent = createSnippet(entry.content, normalizedQuery);
      link.append(title, snippet);
      item.append(link);
      resultList.append(item);
    });

    if (matches.length === 0) {
      appendRecoveryLinks();
    }
  }

  function loadIndex() {
    if (searchIndex) {
      return Promise.resolve(searchIndex);
    }
    if (!loadingIndex) {
      loadingIndex = fetch(form.action, {
        headers: { "Accept": "application/json" },
        credentials: "same-origin"
      }).then(function (response) {
        if (!response.ok) {
          throw new Error("Search index unavailable");
        }
        return response.json();
      }).then(function (data) {
        searchIndex = Array.isArray(data) ? data : [];
        return searchIndex;
      });
    }
    return loadingIndex;
  }

  function search() {
    if (input.value.trim().length < 2) {
      clearResults();
      return;
    }

    status.textContent = "Searching…";
    showPanel();
    loadIndex().then(function () {
      renderResults(input.value);
    }).catch(function () {
      resultList.replaceChildren();
      status.textContent = "Search is temporarily unavailable.";
      showPanel();
      appendRecoveryLinks();
    });
  }

  input.addEventListener("input", search);
  input.addEventListener("keydown", function (event) {
    if (event.key === "Escape") {
      clearResults();
      input.select();
    }
    if (event.key === "ArrowDown" && !panel.hidden) {
      var firstResult = panel.querySelector("a");
      if (firstResult) {
        event.preventDefault();
        firstResult.focus();
      }
    }
  });

  form.addEventListener("submit", function (event) {
    event.preventDefault();
    var firstResult = resultList.querySelector("a");
    if (firstResult) {
      firstResult.click();
    } else {
      search();
    }
  });

  panel.addEventListener("keydown", function (event) {
    if (event.key === "Escape") {
      clearResults();
      input.focus();
    }
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      var links = Array.from(panel.querySelectorAll("a"));
      var currentIndex = links.indexOf(document.activeElement);
      if (currentIndex !== -1) {
        event.preventDefault();
        var nextIndex = event.key === "ArrowDown"
          ? Math.min(links.length - 1, currentIndex + 1)
          : currentIndex - 1;
        if (nextIndex < 0) {
          input.focus();
        } else {
          links[nextIndex].focus();
        }
      }
    }
  });

  document.addEventListener("click", function (event) {
    if (!form.contains(event.target)) {
      clearResults();
    }
  });
}());
