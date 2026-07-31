/* =====================================================================
   palworld-on-oci — landing page behaviour
   Animation is driven by Motion (motion.dev), vendored at assets/motion.min.js
   ===================================================================== */
(function () {
  "use strict";

  var M = window.Motion;
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* If Motion failed to load, make sure nothing stays hidden. */
  if (!M || typeof M.animate !== "function") {
    Array.prototype.forEach.call(document.querySelectorAll(".reveal"), function (el) {
      el.style.opacity = "1";
    });
    settleStatically();
    wireTheme();
    return;
  }

  var animate = M.animate;
  var inView = M.inView;
  var scroll = M.scroll;
  var stagger = M.stagger;
  var hover = M.hover;
  var press = M.press;

  var EASE_OUT = [0.16, 1, 0.3, 1];

  /* ------------------------------------------------------------------
     Theme
     ------------------------------------------------------------------ */
  function wireTheme() {
    var btn = document.getElementById("theme-toggle");
    if (!btn) return;
    btn.addEventListener("click", function () {
      var root = document.documentElement;
      var current = root.getAttribute("data-theme");
      if (!current) {
        current = window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
      }
      var next = current === "dark" ? "light" : "dark";
      root.setAttribute("data-theme", next);
      try {
        localStorage.setItem("pw-theme", next);
      } catch (e) {
        /* storage blocked — the theme still applies for this visit */
      }
    });
  }

  /* ------------------------------------------------------------------
     Final states, used when motion is reduced or unavailable
     ------------------------------------------------------------------ */
  function settleStatically() {
    Array.prototype.forEach.call(document.querySelectorAll(".meter"), function (meter) {
      var pct = parseFloat(meter.getAttribute("data-pct")) || 1;
      var fill = meter.querySelector(".meter-fill");
      if (fill) fill.style.transform = "scaleX(" + pct + ")";
      var val = meter.querySelector("[data-count]");
      if (val) val.textContent = format(parseFloat(val.getAttribute("data-count"))) + val.getAttribute("data-suffix");
    });
  }

  function format(n) {
    return Math.round(n).toLocaleString("en-US");
  }

  /* ------------------------------------------------------------------
     Scroll progress
     ------------------------------------------------------------------ */
  function wireProgress() {
    var bar = document.getElementById("progress");
    if (!bar || typeof scroll !== "function") return;
    scroll(animate(bar, { scaleX: [0, 1] }, { ease: "linear" }));
  }

  /* ------------------------------------------------------------------
     Hero entrance
     ------------------------------------------------------------------ */
  function playHero() {
    var nodes = document.querySelectorAll("[data-hero]");
    if (!nodes.length) return;
    if (reduced) {
      Array.prototype.forEach.call(nodes, function (el) {
        el.style.opacity = "1";
      });
      return;
    }
    Array.prototype.forEach.call(nodes, function (el) {
      el.style.opacity = "0";
    });
    animate(
      nodes,
      { opacity: [0, 1], transform: ["translateY(16px)", "translateY(0px)"] },
      { duration: 0.85, ease: EASE_OUT, delay: stagger(0.09) }
    );
  }

  /* ------------------------------------------------------------------
     Scroll reveals
     ------------------------------------------------------------------ */
  function wireReveals() {
    var seen = new WeakSet();
    Array.prototype.forEach.call(document.querySelectorAll(".reveal"), function (el) {
      if (reduced) {
        el.style.opacity = "1";
        return;
      }
      /* Siblings that reveal together get a short cascade. */
      var siblings = el.parentElement
        ? el.parentElement.querySelectorAll(":scope > .reveal")
        : [el];
      var index = Array.prototype.indexOf.call(siblings, el);
      var delay = Math.min(index, 6) * 0.055;

      inView(
        el,
        function () {
          if (seen.has(el)) return;
          seen.add(el);
          animate(
            el,
            { opacity: [0, 1], transform: ["translateY(14px)", "translateY(0px)"] },
            { duration: 0.7, ease: EASE_OUT, delay: delay }
          );
        },
        { amount: 0.15 }
      );
    });
  }

  /* ------------------------------------------------------------------
     Free-tier meters
     ------------------------------------------------------------------ */
  function wireMeters() {
    var meters = document.querySelectorAll(".meter");
    if (!meters.length) return;
    if (reduced) {
      settleStatically();
      return;
    }

    var seen = new WeakSet();
    Array.prototype.forEach.call(meters, function (meter, i) {
      var pct = parseFloat(meter.getAttribute("data-pct")) || 0;
      var fill = meter.querySelector(".meter-fill");
      var val = meter.querySelector("[data-count]");
      var target = val ? parseFloat(val.getAttribute("data-count")) : 0;
      var suffix = val ? val.getAttribute("data-suffix") : "";

      inView(
        meter,
        function () {
          if (seen.has(meter)) return;
          seen.add(meter);
          var delay = 0.12 + i * 0.12;
          if (fill) {
            animate(fill, { scaleX: [0, pct] }, { duration: 1.15, ease: EASE_OUT, delay: delay });
          }
          if (val) {
            animate(0, target, {
              duration: 1.15,
              ease: EASE_OUT,
              delay: delay,
              onUpdate: function (v) {
                val.textContent = format(v) + suffix;
              }
            });
          }
        },
        { amount: 0.6 }
      );
    });
  }

  /* ------------------------------------------------------------------
     Terminal
     The markup holds the real output, so the panel still reads with
     scripting off; we lift it out, clear it, and type it back in.
     ------------------------------------------------------------------ */
  function wireTerminal() {
    var term = document.getElementById("term");
    var replay = document.getElementById("replay");
    if (!term) return;

    var script = Array.prototype.map.call(term.children, function (el) {
      return {
        text: el.textContent,
        cls: el.className,
        isCmd: el.classList.contains("cmd"),
        pause: parseInt(el.getAttribute("data-pause"), 10) || 0
      };
    });

    if (reduced) {
      if (replay) replay.style.display = "none";
      return;
    }

    var run = 0;

    function sleep(ms) {
      return new Promise(function (resolve) {
        setTimeout(resolve, ms);
      });
    }

    function play() {
      var token = ++run;
      term.textContent = "";

      var caret = document.createElement("span");
      caret.className = "caret typing";

      var step = 0;

      function next() {
        if (token !== run) return;
        if (step >= script.length) {
          caret.classList.remove("typing");
          return;
        }
        var line = script[step++];
        var el = document.createElement("div");
        el.className = line.cls;
        term.appendChild(el);

        if (line.isCmd) {
          el.appendChild(caret);
          typeInto(el, caret, line.text, token, function () {
            sleep(line.pause || 260).then(next);
          });
        } else {
          el.textContent = line.text;
          el.style.opacity = "0";
          term.appendChild(caret);
          animate(el, { opacity: [0, 1] }, { duration: 0.22, ease: "easeOut" });
          sleep(line.pause || 160).then(next);
        }
      }

      next();
    }

    function typeInto(el, caret, text, token, done) {
      var i = 0;
      var buf = document.createTextNode("");
      el.insertBefore(buf, caret);

      function tick() {
        if (token !== run) return;
        if (i >= text.length) {
          done();
          return;
        }
        /* Type in small bursts so it reads like a person, not a modem. */
        var burst = 1 + Math.floor(Math.random() * 2);
        buf.nodeValue = text.slice(0, Math.min(text.length, (i += burst)));
        setTimeout(tick, 16 + Math.random() * 34);
      }

      setTimeout(tick, 90);
    }

    if (replay) {
      replay.addEventListener("click", play);
    }

    /* Only start once the panel is actually on screen. */
    var started = false;
    inView(
      term,
      function () {
        if (started) return;
        started = true;
        setTimeout(play, 420);
      },
      { amount: 0.2 }
    );
  }

  /* ------------------------------------------------------------------
     Micro-interactions
     ------------------------------------------------------------------ */
  function wireInteractions() {
    if (reduced) return;

    if (typeof press === "function") {
      press(".btn, .replay, .theme-toggle", function (element) {
        animate(element, { scale: 0.965 }, { type: "spring", stiffness: 700, damping: 30 });
        return function () {
          animate(element, { scale: 1 }, { type: "spring", stiffness: 500, damping: 22 });
        };
      });
    }

    if (typeof hover === "function") {
      hover(".card", function (element) {
        animate(element, { transform: "translateY(-3px)" }, { duration: 0.28, ease: EASE_OUT });
        return function () {
          animate(element, { transform: "translateY(0px)" }, { duration: 0.32, ease: EASE_OUT });
        };
      });
    }
  }

  /* ------------------------------------------------------------------ */
  wireTheme();
  wireProgress();
  playHero();
  wireReveals();
  wireMeters();
  wireTerminal();
  wireInteractions();
})();
