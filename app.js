/* FixIt Auto Diagnostics & AC — focus cards, job card, WhatsApp hand-off */

(function () {
  "use strict";

  var CFG = {
    wa: "2348129304411",
    phone: "+2348129304411",
    jobs: {
      scan:     { name: "OBD2 Scan",                 price: 15000 },
      acgas:    { name: "AC Gas & Leak Test",        price: 28000 },
      oil:      { name: "Synthetic Oil Service",     price: 38000 },
      brakes:   { name: "Brake Pad & Rotor",         price: 32000 },
      tokunbo:  { name: "Tokunbo Inspection",        price: 25000 }
    }
  };

  var order = ["scan", "acgas", "oil", "brakes", "tokunbo"];
  var picked = {};

  function $(s) { return document.querySelector(s); }
  function $$(s) { return Array.prototype.slice.call(document.querySelectorAll(s)); }

  function naira(n) {
    return "\u20a6" + n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  }

  function ids() {
    return order.filter(function (id) { return picked[id]; });
  }

  function total() {
    return ids().reduce(function (sum, id) { return sum + CFG.jobs[id].price; }, 0);
  }

  function waHref() {
    var list = ids();
    var body = "Hello FixIt \u2014 job card:\n" +
      (list.length ? list.map(function (id) {
        return "- " + CFG.jobs[id].name + " \u2014 " + naira(CFG.jobs[id].price);
      }).join("\n") : "- (no job added yet)") +
      "\nTotal: " + naira(total()) + "\nCar: \nArea: ";
    return "https://wa.me/" + CFG.wa + "?text=" + encodeURIComponent(body);
  }

  var popTimer = null;
  function pop(el) {
    if (!el) return;
    el.classList.remove("pop");
    void el.offsetWidth;
    el.classList.add("pop");
    clearTimeout(popTimer);
    popTimer = setTimeout(function () { el.classList.remove("pop"); }, 240);
  }

  function lineHTML(id) {
    return "<li><span>" + CFG.jobs[id].name + "</span><b>" + naira(CFG.jobs[id].price) + "</b></li>";
  }

  function render() {
    var list = ids();
    var sum = total();

    $$("#cards .card").forEach(function (card) {
      var on = !!picked[card.getAttribute("data-id")];
      card.classList.toggle("is-on", on);
      card.setAttribute("aria-pressed", on ? "true" : "false");
      var add = card.querySelector(".card__add");
      if (add) add.textContent = on ? "Added \u2014 tap to remove" : "Add to job card";
    });

    ["#panelLines", "#drawerList"].forEach(function (sel) {
      var el = $(sel);
      if (!el) return;
      el.innerHTML = list.length
        ? list.map(lineHTML).join("")
        : "<li class=\"empty\">No job added yet.</li>";
    });

    var totalEl = $("#panelTotal");
    if (totalEl && totalEl.textContent !== naira(sum)) {
      totalEl.textContent = naira(sum);
      pop(totalEl);
    }
    var dTotal = $("#drawerTotal");
    if (dTotal) dTotal.textContent = naira(sum);
    var bTotal = $("#barTotal");
    if (bTotal) bTotal.textContent = naira(sum);

    var href = waHref();
    ["#panelCta", "#drawerWa", "#barWa"].forEach(function (sel) {
      var el = $(sel);
      if (el) el.setAttribute("href", href);
    });
  }

  function toggle(id) {
    if (!CFG.jobs[id]) return;
    picked[id] = !picked[id];
    render();
  }

  function scrollToCard() {
    if (!window.matchMedia("(max-width: 1080px)").matches) return;
    var p = $(".panel");
    if (p) p.scrollIntoView({ behavior: "smooth", block: "center" });
  }

  function openDrawer() {
    var d = $("#drawer");
    var s = $("#scrim");
    if (!d) return;
    if (s) { s.hidden = false; void s.offsetWidth; s.classList.add("is-open"); }
    d.classList.add("is-open");
    d.setAttribute("aria-hidden", "false");
    document.body.style.overflow = "hidden";
  }

  function closeDrawer() {
    var d = $("#drawer");
    var s = $("#scrim");
    if (!d) return;
    d.classList.remove("is-open");
    d.setAttribute("aria-hidden", "true");
    if (s) {
      s.classList.remove("is-open");
      setTimeout(function () { s.hidden = true; }, 350);
    }
    document.body.style.overflow = "";
  }

  document.addEventListener("click", function (e) {
    var el = e.target;

    var card = el.closest ? el.closest(".card") : null;
    if (card) {
      toggle(card.getAttribute("data-id"));
      return;
    }

    var filter = el.closest ? el.closest(".filter") : null;
    if (filter) {
      var cat = filter.getAttribute("data-filter");
      $$(".filter").forEach(function (f) { f.classList.toggle("is-on", f === filter); });
      $$("#cards .card").forEach(function (c) {
        var match = cat === "all" || c.getAttribute("data-cat") === cat;
        c.classList.toggle("is-hidden", !match);
      });
      return;
    }

    if (el.closest && el.closest("#barOpen")) { openDrawer(); return; }
    if (el.closest && el.closest("#drawerClose")) { closeDrawer(); return; }
    if (el.closest && el.closest("#scrim")) { closeDrawer(); return; }
  });

  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") closeDrawer();
    var a = document.activeElement;
    if ((e.key === "Enter" || e.key === " ") && a && a.classList && a.classList.contains("card")) {
      e.preventDefault();
      toggle(a.getAttribute("data-id"));
      scrollToCard();
    }
  });

  var boot = document.querySelector(".boot");
  if (boot) {
    setTimeout(function () {
      if (boot && boot.parentNode) boot.parentNode.removeChild(boot);
    }, 2500);
  }

  render();
})();
