const fs = require("fs");
const path = require("path");
const cp = require("child_process");

const INPUT_IPA = process.argv[2] || "miaotaoGOm0492_303_fixed.ipa";
const OUTPUT_IPA = process.argv[3] || "miaotaoGOm0492_303_all_videos.ipa";
const OLD_URL = "https://api.jlyapp.cn/vip1/meet-list";
const NEW_URL = "https://all.jlyapp.cn/vip1/meet-list";

if (Buffer.byteLength(OLD_URL) !== Buffer.byteLength(NEW_URL)) {
  throw new Error("Replacement URL must be the same byte length as original URL");
}

function run(command, args, options = {}) {
  cp.execFileSync(command, args, {
    stdio: "inherit",
    ...options
  });
}

function removePath(target) {
  fs.rmSync(target, { recursive: true, force: true });
}

function copyFile(src, dest) {
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.copyFileSync(src, dest);
}

function patchBinary(file) {
  const oldBytes = Buffer.from(OLD_URL);
  const newBytes = Buffer.from(NEW_URL);
  const data = fs.readFileSync(file);
  let offset = 0;
  let count = 0;
  while ((offset = data.indexOf(oldBytes, offset)) !== -1) {
    newBytes.copy(data, offset);
    count += 1;
    offset += oldBytes.length;
  }
  if (count === 0) {
    throw new Error(`Did not find ${OLD_URL} in ${file}`);
  }
  fs.writeFileSync(file, data);
  return count;
}

function findAppDir(payloadDir) {
  const app = fs.readdirSync(payloadDir).find((name) => name.endsWith(".app"));
  if (!app) throw new Error("Could not find .app inside Payload");
  return path.join(payloadDir, app);
}

function unzipIpa(input, outputDir) {
  removePath(outputDir);
  fs.mkdirSync(outputDir, { recursive: true });
  if (process.platform === "win32") {
    const shell = new ActiveXObjectShim();
    shell.extract(input, outputDir);
  } else {
    run("unzip", ["-q", path.resolve(input), "-d", outputDir]);
  }
}

class ActiveXObjectShim {
  extract(input, outputDir) {
    const command = [
      "$ErrorActionPreference='Stop';",
      "Add-Type -AssemblyName System.IO.Compression.FileSystem;",
      `[IO.Compression.ZipFile]::ExtractToDirectory('${path.resolve(input).replaceAll("'", "''")}', '${path.resolve(outputDir).replaceAll("'", "''")}')`
    ].join(" ");
    run("powershell", ["-NoProfile", "-Command", command]);
  }
}

function zipIpa(payloadRoot, outputIpa) {
  removePath(outputIpa);
  if (process.platform === "win32") {
    const command = [
      "$ErrorActionPreference='Stop';",
      "Add-Type -AssemblyName System.IO.Compression.FileSystem;",
      `[IO.Compression.ZipFile]::CreateFromDirectory('${path.resolve(payloadRoot).replaceAll("'", "''")}', '${path.resolve(outputIpa).replaceAll("'", "''")}')`
    ].join(" ");
    run("powershell", ["-NoProfile", "-Command", command]);
  } else {
    run("zip", ["-qry", path.resolve(outputIpa), "Payload"], { cwd: payloadRoot });
  }
}

function maybeCodesign(appDir) {
  if (process.platform !== "darwin") return false;
  for (const target of [path.join(appDir, "cike.dylib"), appDir]) {
    try {
      run("codesign", ["--force", "--sign", "-", target]);
    } catch (error) {
      console.warn(`codesign skipped for ${target}: ${error.message}`);
    }
  }
  return true;
}

function main() {
  const workDir = path.resolve("build", "ipa-work");
  unzipIpa(INPUT_IPA, workDir);
  const appDir = findAppDir(path.join(workDir, "Payload"));
  const dylib = path.join(appDir, "cike.dylib");
  const patched = patchBinary(dylib);
  removePath(path.join(appDir, "_CodeSignature"));
  const signed = maybeCodesign(appDir);
  zipIpa(workDir, OUTPUT_IPA);
  copyFile(OUTPUT_IPA, path.join("dist", path.basename(OUTPUT_IPA)));
  console.log(JSON.stringify({
    input: INPUT_IPA,
    output: OUTPUT_IPA,
    dist: path.join("dist", path.basename(OUTPUT_IPA)),
    patched,
    signed
  }, null, 2));
}

main();
