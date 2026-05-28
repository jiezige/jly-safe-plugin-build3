const fs = require("fs");
const path = require("path");
const cp = require("child_process");

const ipa = process.argv[2] || "miaotaoGOm0492_303_all_videos.ipa";
const expected = Buffer.from("https://all.jlyapp.cn/vip1/meet-list");
const forbidden = Buffer.from("https://api.jlyapp.cn/vip1/meet-list");

function run(command, args, options = {}) {
  return cp.execFileSync(command, args, { encoding: "utf8", ...options });
}

function removePath(target) {
  fs.rmSync(target, { recursive: true, force: true });
}

function extract(input, outputDir) {
  removePath(outputDir);
  fs.mkdirSync(outputDir, { recursive: true });
  if (process.platform === "win32") {
    const command = [
      "$ErrorActionPreference='Stop';",
      "Add-Type -AssemblyName System.IO.Compression.FileSystem;",
      `[IO.Compression.ZipFile]::ExtractToDirectory('${path.resolve(input).replaceAll("'", "''")}', '${path.resolve(outputDir).replaceAll("'", "''")}')`
    ].join(" ");
    run("powershell", ["-NoProfile", "-Command", command]);
  } else {
    run("unzip", ["-q", path.resolve(input), "-d", outputDir]);
  }
}

function main() {
  const outputDir = path.resolve("build", "verify-ipa");
  extract(ipa, outputDir);
  const appName = fs.readdirSync(path.join(outputDir, "Payload")).find((name) => name.endsWith(".app"));
  const dylib = path.join(outputDir, "Payload", appName, "cike.dylib");
  const data = fs.readFileSync(dylib);
  let expectedCount = 0;
  let offset = 0;
  while ((offset = data.indexOf(expected, offset)) !== -1) {
    expectedCount += 1;
    offset += expected.length;
  }
  if (expectedCount !== 2) {
    throw new Error(`Expected 2 patched URLs, found ${expectedCount}`);
  }
  if (data.includes(forbidden)) {
    throw new Error("Found old red-match URL in patched IPA");
  }
  console.log(`Verified ${ipa}: ${expectedCount} patched URLs`);
}

main();
