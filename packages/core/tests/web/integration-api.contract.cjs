// Real HTTP + OpenAPI 3.1 + response schemas; no fixture credentials in evidence.
const assert = require("node:assert/strict"),
  fs = require("node:fs"),
  os = require("node:os"),
  path = require("node:path"),
  { spawn } = require("node:child_process"),
  { randomBytes, randomUUID, createHash } = require("node:crypto");
const qaRequire = process.env.API_QA_MODULES
  ? (name) => require(path.join(process.env.API_QA_MODULES, name))
  : require;
const Parser = qaRequire("@apidevtools/swagger-parser"),
  Ajv = qaRequire("ajv/dist/2020"),
  addFormats = qaRequire("ajv-formats");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "legnasend-api-contract-")),
  repo = path.resolve(__dirname, "../../../..");
const evidence =
  process.env.EVIDENCE_DIR ||
  path.join(os.tmpdir(), "legnasend-api-contract-evidence");
fs.mkdirSync(evidence, { recursive: true });
fs.mkdirSync(path.join(root, "a"));
fs.mkdirSync(path.join(root, "b"));
const file = Buffer.from("LegnaSend integration 原始文件\n".repeat(25000));
fs.writeFileSync(path.join(root, "a", "hello.txt"), file);
fs.writeFileSync(path.join(root, "b", "hidden.txt"), "explicit key grant only");
const secret =
    "ls1." + randomUUID() + "." + randomBytes(32).toString("base64url"),
  workspace = "11111111-1111-4111-8111-111111111111";
let fixture,
  output = "";
async function until(fn) {
  for (let i = 0; i < 400; i++) {
    const v = await fn();
    if (v) return v;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw Error("timeout");
}
(async () => {
  fixture = spawn(
    path.join(
      repo,
      "target",
      "debug",
      "examples",
      process.platform === "win32"
        ? "integration_api_fixture.exe"
        : "integration_api_fixture",
    ),
    [root],
    { env: { ...process.env, LEGNASEND_FIXTURE_API_TOKEN: secret } },
  );
  fixture.stdout.on("data", (d) => (output += d));
  fixture.stderr.on("data", (d) => process.stderr.write(d));
  const url = await until(
      () => output.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0],
    ),
    base = url + "api/legnasend/v1/integration";
  const request = (route, options = {}) =>
    fetch(base + route, {
      ...options,
      headers: { Authorization: "Bearer " + secret, ...options.headers },
      signal: AbortSignal.timeout(8000),
    });
  const en = await (await request("/openapi.json")).json();
  await Parser.validate(structuredClone(en));
  const ajv = new Ajv({ strict: false, allErrors: true });
  addFormats(ajv);
  ajv.addSchema(en, "api");
  const validated = [];
  for (const [route, schema] of [
    ["/status", "Status"],
    ["/capabilities", "Capabilities"],
    ["/workspaces", "WorkspaceList"],
    ["/workspaces/" + workspace, "Workspace"],
    ["/workspaces/" + workspace + "/files?generation=1", "FilePage"],
    ["/requests", "RequestPage"],
  ]) {
    const r = await request(route);
    assert.equal(r.status, 200);
    const data = await r.json(),
      validate = ajv.compile({ $ref: "api#/components/schemas/" + schema });
    assert.ok(validate(data), JSON.stringify(validate.errors));
    validated.push(schema);
  }
  const docs = {};
  for (const language of ["en", "zh-CN", "zh-TW", "zh-HK"]) {
    const data = await (await request("/openapi.json?lang=" + language)).json();
    await Parser.validate(structuredClone(data));
    docs[language] = data;
  }
  assert.notEqual(
    docs.en.paths["/status"].get.summary,
    docs["zh-CN"].paths["/status"].get.summary,
  );
  const content =
    "/workspaces/" +
    workspace +
    "/files/" +
    Buffer.from("hello.txt").toString("base64url") +
    "/content?generation=1";
  const head = await request(content, { method: "HEAD" });
  assert.equal(Number(head.headers.get("content-length")), file.length);
  const etag = head.headers.get("etag");
  const range = await request(content, {
    headers: { Range: "bytes=17-65552", "If-Match": etag },
  });
  assert.equal(range.status, 206);
  assert.deepEqual(
    Buffer.from(await range.arrayBuffer()),
    file.subarray(17, 65553),
  );
  const whole = Buffer.from(await (await request(content)).arrayBuffer());
  assert.equal(
    createHash("sha256").update(whole).digest("hex"),
    createHash("sha256").update(file).digest("hex"),
  );
  const invalid = await fetch(base + "/status?token=DO-NOT-RECORD", {
    headers: { Authorization: "Bearer " + secret },
  });
  assert.equal(invalid.status, 400);
  const error = await invalid.json();
  const check = ajv.compile({ $ref: "api#/components/schemas/Error" });
  assert.ok(check(error));
  async function command(value) {
    const at = output.length;
    fixture.stdin.write(value + "\n");
    await until(() => output.slice(at).includes("revision"));
  }
  await command("anonymous");
  const index = await (await fetch(base + "/workspaces")).json();
  assert.equal(index.workspaces.length, 1);
  assert.equal(index.workspaces[0].id, workspace);
  const open = await (await request("/openapi.json")).json();
  await Parser.validate(structuredClone(open));
  assert.deepEqual(open.paths["/status"].get.security, [
    { bearerAuth: [] },
    {},
  ]);
  const requests = await (await request("/requests?limit=100")).json();
  assert.ok(!JSON.stringify(requests).includes(secret));
  assert.ok(!JSON.stringify(requests).includes("DO-NOT-RECORD"));
  assert.ok(!JSON.stringify(requests).includes(root));
  await command("revoke");
  assert.equal((await request("/status")).status, 401);
  assert.equal((await fetch(base + "/status")).status, 200);
  await command("disable");
  assert.equal((await fetch(base + "/status")).status, 404);
  assert.equal((await fetch(url + "api/legnasend/v1/workspaces")).status, 200);
  // Documents contain no environment-specific host, key, path or request history.
  for (const [language, data] of Object.entries(docs))
    fs.writeFileSync(
      path.join(evidence, "integration-openapi-" + language + ".json"),
      JSON.stringify(data, null, 2) + "\n",
    );
  const result = {
    openapi: "3.1.0",
    paths: Object.keys(en.paths).length,
    operations: Object.values(en.paths).reduce(
      (n, p) => n + Object.keys(p).length,
      0,
    ),
    languages: Object.keys(docs),
    responseSchemas: validated,
    sourceBytes: file.length,
    sha256: createHash("sha256").update(file).digest("hex"),
    range: "bytes 17-65552/" + file.length,
    anonymousFiltered: true,
    revoked: true,
    disabled: true,
    browserApiIndependent: true,
    auditRedacted: true,
  };
  fs.writeFileSync(
    path.join(evidence, "integration-api-results.json"),
    JSON.stringify(result, null, 2) + "\n",
  );
  console.log(JSON.stringify(result));
})()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(async () => {
    if (fixture) {
      fixture.stdin.end("quit\n");
      await Promise.race([
        new Promise((r) => fixture.once("exit", r)),
        new Promise((r) =>
          setTimeout(() => {
            fixture.kill();
            r();
          }, 2000).unref(),
        ),
      ]);
    }
    fs.rmSync(root, { recursive: true, force: true });
  });
