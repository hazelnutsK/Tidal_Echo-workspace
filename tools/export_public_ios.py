#!/usr/bin/env python3
"""Export committed iOS source to the public build branch; compile only with --build."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PUBLIC = "hazelnutsK/Tidal_Echo"
BRANCH = "ios-build"
WORKFLOW = ".github/workflows/ios-build.yml"
PATTERNS = re.compile(rb"sk-(?:ant-|or-)?[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----|\b\d{8,12}:[A-Za-z0-9_-]{25,}")
ENV = dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="Never")

def git(*args, cwd=None, env=ENV, check=True, data=None):
    cwd = ROOT if cwd is None else cwd
    timeout = 180 if args and args[0] in ("fetch", "push") else 55
    r = subprocess.run(["git", *args], cwd=cwd, env=env, input=data,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if check and r.returncode:
        raise RuntimeError("Git operation failed: " + r.stderr.decode("utf-8", errors="replace")[-1200:])
    return r

def text(*args, **kwargs):
    return git(*args, **kwargs).stdout.decode("utf-8").strip()

def api(path, token, method="GET", data=None, missing_ok=False):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "Tidal-Echo-public-iOS-export",
               "Authorization": "Bearer " + token}
    body = json.dumps(data).encode() if data is not None else None
    if body is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request("https://api.github.com/" + path, headers=headers, data=body, method=method)
    try:
        with urllib.request.urlopen(req, timeout=25) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        if missing_ok and error.code == 404:
            return None
        raise RuntimeError("GitHub API returned " + str(error.code) + " for " + path) from None

def authentication():
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        r = git("credential", "fill", data=b"protocol=https\nhost=github.com\n\n", check=False)
        credential = dict(line.split("=", 1) for line in r.stdout.decode().splitlines() if "=" in line)
        token = credential.get("password")
    if not token:
        raise RuntimeError("Public publishing needs an authenticated GitHub account on this machine. The private VPS deploy key cannot publish to the public repository.")
    env = dict(ENV)
    env.update({"GIT_CONFIG_COUNT": "3",
                "GIT_CONFIG_KEY_0": "credential.helper", "GIT_CONFIG_VALUE_0": "",
                "GIT_CONFIG_KEY_1": "http.https://github.com/.extraHeader",
                "GIT_CONFIG_VALUE_1": "Authorization: Basic " + base64.b64encode(("x-access-token:" + token).encode()).decode(),
                "GIT_CONFIG_KEY_2": "http.version", "GIT_CONFIG_VALUE_2": "HTTP/1.1"})
    if os.name == "nt":
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Internet Settings") as settings:
            enabled = winreg.QueryValueEx(settings, "ProxyEnable")[0]
            proxy = winreg.QueryValueEx(settings, "ProxyServer")[0]
        match = re.search(r"(?:^|;)http=([^;]+)", proxy)
        if match:
            proxy = match[1]
        if enabled and re.fullmatch(r"127\.0\.0\.1:\d+", proxy):
            env.update({"GIT_CONFIG_COUNT": "4", "GIT_CONFIG_KEY_3": "http.proxy", "GIT_CONFIG_VALUE_3": "http://" + proxy})
    return token, env

def private_values():
    values = set()
    key_pattern = re.compile("key|secret|token|password|authorization", re.I)
    live = Path.home() / "Tidal_Echo"
    for name in ("backend/relay.env", "examples/.env", "wechat/.env"):
        p = live / name
        if not p.is_file():
            continue
        for line in p.read_text(encoding="utf-8-sig").splitlines():
            if line.lstrip().startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.strip().strip("\"'")
            if key_pattern.search(k) and len(v) >= 10:
                values.add(v.encode())
    return values

def validate_path(path, mode):
    p = PurePosixPath(path)
    if p.is_absolute() or ".." in p.parts or ":" in path or mode not in ("100644", "100755"):
        raise RuntimeError("Unsupported export entry: " + path)
    if not (path.startswith("ios/") or path in (WORKFLOW, "LICENSE")):
        raise RuntimeError("File outside the iOS export allowlist: " + path)
    if re.search(r"(^|/)(?:\.env|\.mcp\.json|uploads|inbox|artifacts|previews|DerivedData[^/]*|NativePreviews|IMessageScreenshots)(/|$)|\.(?:db|sqlite\d*|ipa|zip|log|pem|key)$|\.xcresult(/|$)", path, re.I):
        raise RuntimeError("Runtime, private or build data refused: " + path)

def export(ref, destination):
    sha = text("rev-parse", "--verify", ref + "^{commit}")
    entries = git("ls-tree", "-r", "-z", sha, "--", "ios", WORKFLOW, "LICENSE").stdout.split(b"\0")
    known = private_values()
    manifest = []
    for entry in entries:
        if not entry:
            continue
        meta, raw_path = entry.split(b"\t", 1)
        mode, kind, blob = meta.decode().split()
        path = raw_path.decode("utf-8")
        validate_path(path, mode)
        data = git("cat-file", "blob", blob).stdout
        if PATTERNS.search(data) or any(value in data for value in known):
            raise RuntimeError("Possible credential in source; export refused: " + path)
        p = destination / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        if os.name != "nt":
            p.chmod(0o755 if mode == "100755" else 0o644)
        manifest.append({"path": path, "sha256": hashlib.sha256(data).hexdigest(), "mode": mode})
    workflow = (destination / WORKFLOW).read_text(encoding="utf-8-sig")
    trigger = re.search(r"(?m)^on:\s*\n([\s\S]*?)(?=^\S|\Z)", workflow)
    events = re.findall(r"(?m)^  ([a-z_]+):", trigger.group(1) if trigger else "")
    if events != ["workflow_dispatch"]:
        raise RuntimeError("The exported workflow must be manual-only.")
    if re.findall(r"(?m)^\s*runs-on:\s*(\S+)", workflow) != ["macos-26"]:
        raise RuntimeError("Review any runner change before publishing this build workflow.")
    required = [WORKFLOW, "LICENSE", "ios/project.yml", "ios/scripts/prepare-assets.sh", "ios/Assets/AppIconSource.png"]
    if any(not (destination / p).is_file() for p in required):
        raise RuntimeError("Required build source is missing.")
    for p in destination.rglob("*.py"):
        compile(p.read_bytes().decode("utf-8-sig"), str(p), "exec")
    record = {"source_commit": sha, "ios_tree": text("rev-parse", sha + ":ios"), "files": manifest}
    (destination / "source-manifest.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (destination / "README.md").write_text(
        "# Tidal Echo iOS build source\n\n"
        "This branch contains published iOS source, tests, assets and the manual build workflow.\n"
        "The server backend, credentials, conversations and other private runtime data are excluded.\n\n"
        "Build: Actions -> iOS Build -> Run workflow -> choose ios-build.\n"
        "Pushing a source snapshot does not start a build. The source-manifest.json records\n"
        "the exact source commit and file hashes used for this snapshot.\n", encoding="utf-8")
    return record

def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--ref", default="HEAD", help="committed private source to export; never uses uncommitted files")
    p.add_argument("--publish", action="store_true", help="publish inspected source to the public ios-build branch")
    p.add_argument("--build", action="store_true", help="also manually dispatch the public workflow")
    p.add_argument("--review-only", action="store_true", help="dispatch native review without an IPA")
    args = p.parse_args()
    if args.build and not args.publish:
        p.error("--build requires --publish")
    if args.review_only and not args.build:
        p.error("--review-only requires --build")
    sha = text("rev-parse", "--verify", args.ref + "^{commit}")
    if args.ref == "HEAD" and text("status", "--porcelain"):
        raise RuntimeError("Working tree has uncommitted changes. Commit/push first or explicitly select a committed --ref.")
    with tempfile.TemporaryDirectory(prefix="tidal-public-ios-") as folder:
        dest = Path(folder)
        record = export(sha, dest)
        result = {"source_commit": sha, "ios_files": sum(x["path"].startswith("ios/") for x in record["files"]),
                  "credential_scan": "passed", "public_branch": BRANCH, "build_dispatched": False}
        if not args.publish:
            result["mode"] = "preview"
            print(json.dumps(result, ensure_ascii=False))
            return
        token, env = authentication()
        repo = api("repos/" + PUBLIC, token)
        if repo["private"] or not repo["permissions"].get("push"):
            raise RuntimeError("Expected writable public build repository.")
        # Verify that the selected source commit is already synced to the private GitHub repo.
        private = api("repos/hazelnutsK/Tidal_Echo-workspace/commits/" + sha, token)
        if private["sha"] != sha:
            raise RuntimeError("Private source commit has not been pushed.")
        ref = api("repos/" + PUBLIC + "/git/ref/heads/" + BRANCH, token, missing_ok=True)
        # Manual dispatch needs the workflow registered on the public default branch.
        api("repos/" + PUBLIC + "/contents/" + WORKFLOW + "?ref=" + repo["default_branch"], token)
        git("init", "-b", BRANCH, cwd=dest)
        git("config", "core.autocrlf", "false", cwd=dest)
        git("config", "user.name", "Tidal Echo source sync", cwd=dest)
        git("config", "user.email", "hazelnutsK@users.noreply.github.com", cwd=dest)
        git("remote", "add", "origin", "https://github.com/" + PUBLIC + ".git", cwd=dest)
        parent = None
        if ref:
            git("fetch", "--depth=1", "origin", "refs/heads/" + BRANCH, cwd=dest, env=env)
            parent = text("rev-parse", "FETCH_HEAD", cwd=dest)
            if parent != ref["object"]["sha"]:
                raise RuntimeError("Public branch changed concurrently; retry export.")
            previous = git("show", parent + ":source-manifest.json", cwd=dest, check=False)
            if previous.returncode:
                raise RuntimeError("Existing public branch is not managed by this exporter.")
        git("add", "-f", "--all", cwd=dest)
        for item in record["files"]:
            git("update-index", "--chmod=" + ("+x" if item["mode"] == "100755" else "-x"), "--", item["path"], cwd=dest)
        tree = text("write-tree", cwd=dest)
        needs_push = not (parent and tree == text("rev-parse", parent + "^{tree}", cwd=dest))
        if not needs_push:
            public_sha = parent
        else:
            command = ["commit-tree", tree, "-m", "Publish iOS source " + sha[:12]]
            if parent:
                command += ["-p", parent]
            public_sha = text(*command, cwd=dest)
        if text("rev-parse", public_sha + ":ios", cwd=dest) != record["ios_tree"]:
            raise RuntimeError("Public iOS tree differs from the selected source.")
        if needs_push:
            # Validate the complete tree before publishing; normal pushes refuse races.
            git("push", "origin", public_sha + ":refs/heads/" + BRANCH, cwd=dest, env=env)
        published = api("repos/" + PUBLIC + "/git/ref/heads/" + BRANCH, token)
        if published["object"]["sha"] != public_sha:
            raise RuntimeError("Remote public commit verification failed.")
        result.update({"mode": "published", "public_commit": public_sha,
                       "url": "https://github.com/" + PUBLIC + "/tree/" + BRANCH})
        if args.build:
            api("repos/" + PUBLIC + "/actions/workflows/ios-build.yml/dispatches", token, "POST",
                {"ref": BRANCH, "inputs": {"native_review_only": str(args.review_only).lower()}})
            result["build_dispatched"] = True
            result["actions_url"] = "https://github.com/" + PUBLIC + "/actions/workflows/ios-build.yml"
        print(json.dumps(result, ensure_ascii=False))

if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

