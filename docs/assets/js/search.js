(function () {
  "use strict";

  document.documentElement.classList.add("js");

  var navToggle = document.querySelector(".nav-toggle");
  var navigation = document.getElementById("site-navigation");
  var narrowViewport = window.matchMedia("(max-width: 820px)");

  function syncNavigation() {
    if (!navToggle || !navigation) {
      return;
    }

    if (narrowViewport.matches) {
      navigation.hidden = navToggle.getAttribute("aria-expanded") !== "true";
    } else {
      navigation.hidden = false;
      navToggle.setAttribute("aria-expanded", "false");
    }
  }

  if (navToggle && navigation) {
    navToggle.addEventListener("click", function () {
      var expanded = navToggle.getAttribute("aria-expanded") === "true";
      navToggle.setAttribute("aria-expanded", String(!expanded));
      navigation.hidden = expanded;
      if (!expanded) {
        var currentLink = navigation.querySelector('[aria-current="page"]');
        var firstLink = navigation.querySelector("a");
        (currentLink || firstLink || navigation).focus();
      }
    });

    navigation.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && narrowViewport.matches && !navigation.hidden) {
        navigation.hidden = true;
        navToggle.setAttribute("aria-expanded", "false");
        navToggle.focus();
      }
    });

    narrowViewport.addEventListener("change", syncNavigation);
    syncNavigation();
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
    input.setAttribute("aria-expanded", "false");
  }

  function showPanel() {
    panel.hidden = false;
    input.setAttribute("aria-expanded", "true");
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
    secondLink.textContent = "feature index";
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
    var matches = searchIndex.filter(function (entry) {
      var searchable = normalize(entry.title + " " + entry.content);
      return terms.some(function (term) {
        return searchable.includes(term);
      });
    }).slice(0, 8);

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
