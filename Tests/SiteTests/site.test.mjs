import assert from "node:assert/strict";
import { generateKeyPairSync, sign, webcrypto } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("../../site/site.js", import.meta.url), "utf8");
const configuredKey = source.match(/const PUBLIC_KEY = "([^"]+)"/)[1];
const keys = generateKeyPairSync("ed25519");
const publicKey = Buffer.from(keys.publicKey.export({ format: "jwk" }).x, "base64url").toString("base64");
const fallback = "https://github.com/rselbach/baby/releases/latest";
const prefix = "https://github.com/rselbach/baby/releases/download/v1.2.0/";

function release() {
  return {
    schema: 1, app: "com.rselbach.baby", channel: "stable", version: "1.2.0",
    artifacts: [
      { os: "macos", arch: "arm64", kind: "app-zip", minimum_os: "14.0", url: prefix + "Baby.zip" },
      { os: "macos", arch: "arm64", kind: "dmg", minimum_os: "14.0", url: prefix + "Installer.dmg" },
    ],
  };
}

function envelope(value, context = "baby-update-feed-v1\n") {
  const payload = Buffer.from(JSON.stringify(value));
  return {
    payload: payload.toString("base64"),
    signature: sign(null, Buffer.concat([Buffer.from(context), payload]), keys.privateKey).toString("base64"),
  };
}

async function render(feed, crypto = webcrypto) {
  const elements = new Map();
  function element(id) {
    if (!elements.has(id)) {
      elements.set(id, {
        href: id === "download" ? fallback : "",
        hidden: true,
        classList: { toggle() { this.asleep = !this.asleep; return this.asleep; } },
        addEventListener(name, handler) { this[name] = handler; },
        setAttribute(name, value) { this[name] = value; },
        replaceChildren(...children) { this.children = children; },
      });
    }
    return elements.get(id);
  }
  const warnings = [];
  const code = source.replace(configuredKey, publicKey);
  await vm.runInNewContext(code, {
    document: {
      getElementById: element,
      querySelector: element,
      createElement: () => ({}),
    },
    fetch: async () => new Response(JSON.stringify(feed)),
    crypto, TextEncoder, TextDecoder, URL, atob, Uint8Array,
    console: { warn: (...args) => warnings.push(args) },
  });
  await new Promise((resolve) => setImmediate(resolve));
  return { element, warnings };
}

test("uses the signed DMG URL rather than deriving a filename", async () => {
  const { element, warnings } = await render(envelope(release()));
  assert.equal(element("download").href, prefix + "Installer.dmg");
  assert.equal(element("download-others").hidden, false);
  assert.equal(warnings.length, 0);
});

test("strips all trailing .0 components from minimum_os", async () => {
  for (const [minimumOS, expected] of [
    ["14", "14"],
    ["14.0", "14"],
    ["14.0.0", "14"],
    ["14.2.0", "14.2"],
    ["14.0.1", "14.0.1"],
  ]) {
    const value = release();
    value.artifacts[1].minimum_os = minimumOS;
    const { element, warnings } = await render(envelope(value));
    assert.equal(element("download-meta").children[1], ` · Apple silicon, macOS ${expected} or later`);
    assert.equal(warnings.length, 0);
  }
});

test("uses a verification key the app trusts", () => {
  const feed = readFileSync(new URL("../../Sources/BabyUpdate/Feed.swift", import.meta.url), "utf8");
  const legacy = feed.match(/public static let legacyPublicKey = "([^"]+)"/)[1];
  const trusted = feed.match(/public static let publicKeys = \[([^\]]*)\]/)[1]
    .split(",").map((item) => item.trim())
    .map((item) => (item === "legacyPublicKey" ? legacy : JSON.parse(item)));
  assert.ok(trusted.includes(configuredKey), `${configuredKey} is not in ${trusted}`);
});

test("accepts a feed whose own key's signature is in signatures", async () => {
  const other = generateKeyPairSync("ed25519");
  const feed = envelope(release());
  const message = Buffer.concat([
    Buffer.from("baby-update-feed-v1\n"), Buffer.from(feed.payload, "base64"),
  ]);
  feed.signatures = [feed.signature];
  feed.signature = sign(null, message, other.privateKey).toString("base64");
  const { element, warnings } = await render(feed);
  assert.equal(element("download").href, prefix + "Installer.dmg");
  assert.equal(warnings.length, 0);

  // without our key's signature anywhere, the fallback stays
  feed.signatures = [];
  const unsigned = await render(feed);
  assert.equal(unsigned.element("download").href, fallback);
  assert.equal(unsigned.warnings.length, 1);
});

test("keeps the fallback for tampering or a missing signature", async () => {
  const tampered = envelope(release());
  const changed = release();
  changed.version = "9.9.9";
  tampered.payload = Buffer.from(JSON.stringify(changed)).toString("base64");
  for (const feed of [tampered, { payload: envelope(release()).payload }]) {
    const { element } = await render(feed);
    assert.equal(element("download").href, fallback);
  }
});

test("requires the signing context and expected app and channel", async () => {
  const wrongApp = { ...release(), app: "com.greendale.other" };
  const wrongChannel = { ...release(), channel: "beta" };
  for (const feed of [envelope(release(), ""), envelope(wrongApp), envelope(wrongChannel)]) {
    const { element } = await render(feed);
    assert.equal(element("download").href, fallback);
  }
});

test("rejects unsafe signed artifact URLs", async () => {
  for (const url of [prefix + "../../../../other/Installer.dmg", prefix + "Installer.dmg?x=1", "https://greendale.example/Installer.dmg"]) {
    const value = release();
    value.artifacts[1].url = url;
    const { element } = await render(envelope(value));
    assert.equal(element("download").href, fallback);
  }
});

test("keeps the fallback for legacy feeds and unsupported cryptography", async () => {
  const legacy = release();
  legacy.artifacts.pop();
  assert.equal((await render(envelope(legacy))).element("download").href, fallback);
  assert.equal((await render(envelope(release()), {})).element("download").href, fallback);
});

test("the awake demo remains usable without a verified feed", async () => {
  const { element } = await render({});
  element("toggle").click();
  assert.equal(element("toggle")["aria-pressed"], "false");
  assert.equal(element("#state span").textContent, "Sleep allowed");
});
