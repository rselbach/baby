// Runs the hero's awake/asleep demo and points the download button at the
// latest DMG from Baby's signed update feed. Without the feed, the button
// keeps its link to the latest release.
"use strict";

(() => {
  const FEED_URL = "https://rselbach.github.io/baby/update.json";
  const ASSET_PREFIX = "https://github.com/rselbach/baby/releases/download/";
  const PUBLIC_KEY = "2obyIySbPw8xSuXQwzSw2sCbOixUww08jk95se82unc=";

  const page = document.getElementById("page");
  const toggle = document.getElementById("toggle");
  const label = document.querySelector("#state span");
  toggle.addEventListener("click", () => {
    const asleep = page.classList.toggle("asleep");
    toggle.setAttribute("aria-pressed", String(!asleep));
    label.textContent = asleep ? "Sleep allowed" : "Keeping your Mac awake";
  });

  async function loadRelease() {
    const response = await fetch(FEED_URL);
    if (!response.ok) throw new Error(`feed returned ${response.status}`);
    const body = await response.arrayBuffer();
    if (body.byteLength > 64 * 1024) throw new Error("feed is too large");
    const { payload, signature } = JSON.parse(new TextDecoder().decode(body));
    const bytes = decodeBase64(payload);
    const context = new TextEncoder().encode("baby-update-feed-v1\n");
    const message = new Uint8Array(context.length + bytes.length);
    message.set(context);
    message.set(bytes, context.length);
    const key = await crypto.subtle.importKey("raw", decodeBase64(PUBLIC_KEY), "Ed25519", false, ["verify"]);
    if (!await crypto.subtle.verify("Ed25519", key, decodeBase64(signature), message)) {
      throw new Error("feed signature is invalid");
    }
    const release = JSON.parse(new TextDecoder().decode(bytes));
    if (release.schema !== 1 || release.app !== "com.rselbach.baby" || release.channel !== "stable" ||
        typeof release.version !== "string" || !/^\d+(\.\d+){0,2}$/.test(release.version) ||
        !Array.isArray(release.artifacts)) {
      throw new Error("feed payload is not a stable Baby release");
    }
    return release;
  }

  function decodeBase64(value) {
    if (typeof value !== "string") throw new Error("missing encoded feed field");
    return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
  }

  function safeURL(value, prefix) {
    if (typeof value !== "string" || !value.startsWith(prefix)) return false;
    try {
      const url = new URL(value);
      const parts = decodeURIComponent(url.pathname).split("/");
      return url.href === value && !value.includes("?") && !value.includes("#") &&
        !parts.some((part) => part === "." || part === "..");
    } catch {
      return false;
    }
  }

  function link(text, href) {
    const a = document.createElement("a");
    a.href = href;
    a.textContent = text;
    return a;
  }

  async function main() {
    const release = await loadRelease();
    const artifacts = release.artifacts.filter(
      (a) => a && a.os === "macos" && a.arch === "arm64" && safeURL(a.url, ASSET_PREFIX),
    );
    const dmg = artifacts.find((a) => a.kind === "dmg");
    const zip = artifacts.find((a) => a.kind === "app-zip");
    if (!dmg || typeof dmg.minimum_os !== "string" || !/^\d+(\.\d+){0,2}$/.test(dmg.minimum_os)) {
      throw new Error("feed has no supported macOS DMG");
    }

    document.getElementById("download").href = dmg.url;

    const major = dmg.minimum_os.replace(/\.0$/, "");
    const version = `Version ${release.version}`;
    const notes = safeURL(release.notes_url, "https://github.com/rselbach/baby/")
      ? link(version, release.notes_url)
      : version;
    document.getElementById("download-meta").replaceChildren(
      notes, ` · Apple silicon, macOS ${major} or later`,
    );
    if (zip) {
      const others = document.getElementById("download-others");
      others.replaceChildren("Also available as a ", link("ZIP", zip.url));
      others.hidden = false;
    }
  }

  return main().catch((error) => console.warn("Baby download button:", error));
})();
