"""Generate chNN/try-it-now.sh from the book's TRY IT NOW blocks.

blocks.json holds each chapter's command blocks in book order, extracted from
the book text in the llm-wiki repo (raw/kubernetes-in-a-month-of-lunches-*.md).

usage: python3 tools/try-it-now/gen.py            (from the repo root)
       python3 tools/try-it-now/gen.py --test     (self-check)
"""
import json
import os
import re
import shlex
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

# Windows-only lines; the book prints a bash equivalent next to each.
POWERSHELL = re.compile(r"\.ps1\b|^powershell|\$env:|Invoke-|Set-ExecutionPolicy|^\.\s+\.\\|^\.\\")
# Host setup a script on a local kind cluster can't do.
MANUAL = re.compile(
    r"^(vagrant|sudo|ssh|kubeadm|exit$|docker|buildctl)\b|^cd (/|ch01)|^kind create|<[a-z_]+>"
    r"|kubectl config (use|set)-context (?!--current)"
)
# Book comments that say the next command fails.
EXPECT_FAIL = re.compile(
    r"will fail|this fails|won['’]t work|you['’]ll (get|see) an error|"
    r"can['’]t (delete|list|read|access|see)|forbidden|denied",
    re.I,
)
# Commands that fail because this fork deliberately differs from the book.
DIFFERS = {
    r"/etc/nginx/nginx\.conf": "the nginx ingress controller is Traefik in this fork (ingress-nginx is archived)",
}
DEPLOYS = re.compile(r"^(kubectl (apply|create|scale|rollout undo|set|label|expose|run)|helm (install|upgrade|rollback))\b")
SHELLS = {"sh", "bash", "/bin/sh", "/bin/bash"}

# Fixes for book typos and commands that changed in current kubectl.
REPLACE = [
    (r"[‘’]", "'"),
    (r"[“”]", '"'),
    (r"\.status\.loadBalancer\.ingress\[0\]\.\*\}", ".status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}"),
    (r"--cascade=false\b", "--cascade=orphan"),
    (r"kubectl version --short", "kubectl version"),
    (r"^pi-proxy$", "kubectl get ds pi-proxy"),
    (r"node-role\.kubernetes\.io/master-", "node-role.kubernetes.io/control-plane-"),
]


def join_wrapped(lines):
    """The book wraps long commands; continuation lines start with whitespace or '-'."""
    out = []
    for line in lines:
        if out and out[-1].endswith("/") and line and not line[0].isspace() and " " not in line:
            out[-1] += line.strip()  # URL split across lines
        elif out and line.strip() and (line[0].isspace() or line.startswith("-")) and not out[-1].startswith("#"):
            out[-1] = out[-1].rstrip(" \\") + " " + line.strip()
        else:
            out.append(line.rstrip())
    return out


def convert_block(chapter, lines):
    lines = join_wrapped(lines)
    body, expect, i = [], False, 0
    while i < len(lines):
        line = lines[i].strip()
        for pat, rep in REPLACE:
            line = re.sub(pat, rep, line)
        i += 1
        if not line:
            continue
        if line.startswith("#"):
            expect = bool(EXPECT_FAIL.search(line))
            body.append(line)
            url = re.search(r"browse to (https?://[^\s<>]+?)[.,]?(\s|$)", line)
            if url:
                body.append(f"browse {url.group(1)}")
            continue
        if POWERSHELL.search(line) or line == f"cd {chapter}":
            continue
        if line == "ctrl-c":
            body.append("pf_stop")
            continue
        m = re.match(r"^(chmod \+x \S+ && )?\./(add-to-hosts|add-todo-to-hosts)\.sh\s*(.*)$", line)
        if m:
            args = m.group(3).split() or ["todo.kiamol.local", "ingress-nginx"]
            hosts = [args[0]] if m.group(2) == "add-to-hosts" else ["todo.kiamol.local", "api.todo.kiamol.local"]
            ctl = args[1] if m.group(2) == "add-to-hosts" else "ingress-nginx"
            body += [f"hosts_add {h} {ctl}" for h in hosts]
            continue
        if MANUAL.search(line):
            body.append(f"manual {shlex.quote(line)}")
            continue
        words = line.split()
        if line.startswith("kubectl port-forward "):
            cmd = "pf_start " + line[len("kubectl port-forward "):]
        elif re.search(r"\s-(it|ti)\s", line) and words[-1] in SHELLS:
            # interactive shell: send the lines up to "exit" into it
            inner = []
            while i < len(lines) and lines[i].strip() != "exit":
                if lines[i].strip() and not lines[i].strip().startswith("#"):
                    inner.append(lines[i].strip())
                i += 1
            i += 1
            cmd = re.sub(r"\s-(it|ti)\s", " -i ", line) + " <<'EOF'", "\n".join(inner) + "\nEOF"
        elif re.search(r"\s-(it|ti)\s", line):
            cmd = re.sub(r"\s-(it|ti)\s", " ", line)
        elif re.search(r"\s(--watch|-w)\b|logs .*(-f|--follow)\b", line):
            cmd = f"bounded 20 {line}"
        elif re.match(r"^kubectl get .* -o jsonpath='https?://", line):
            cmd = f'browse "$({line})"'
        else:
            cmd = line
        for pat, why in DIFFERS.items():
            if re.search(pat, line):
                body.append(f"# differs from the book: {why}")
                expect = True
        if isinstance(cmd, tuple):  # heredoc: command line, then its body
            body.append(cmd[0] + (" || expected" if expect else "") + "\n" + cmd[1])
        else:
            body.append(cmd + (" || expected" if expect else ""))
        expect = False  # a book comment describes the one command after it
        if DEPLOYS.match(line):
            body.append("settle")
    return body


def generate(chapter, blocks):
    out = [
        "#!/usr/bin/env bash",
        f"# The book's TRY IT NOW commands for {chapter}, generated by tools/try-it-now/gen.py.",
        "# Run from anywhere: ./try-it-now.sh runs every block, ./try-it-now.sh 3 5 runs blocks 3 and 5.",
        "# Needs a cluster from ./cluster.sh up. Browsing and /etc/hosts edits are replaced by curl checks.",
        f"chapter={chapter}",
        'cd "$(dirname "$0")" || exit',
        "source ../tools/try-it-now/lib.sh",
    ]
    for n, lines in enumerate(blocks, 1):
        body = convert_block(chapter, lines) or [":"]
        out += ["", f"block_{n}() {{"] + ["  " + l for l in body] + ["}"]
    out += ["", 'main "$@"', ""]
    return "\n".join(out)


def test():
    got = convert_block("ch02", [
        "cd ch02",
        "kubectl apply -f x.yaml",
        "kubectl get svc a -o jsonpath='http://{.status.loadBalancer.ingress[0].*}:8080'",
        "# this will fail:",
        "kubectl exec -it deploy/s -- sh",
        "hostname -i",
        "exit",
        "kubectl get pods",
        "# browse to http://a.local/x, then",
        "kubectl get secret x -o",
        "    jsonpath='{.data}'",
        "./add-to-hosts.ps1 a.local ingress-nginx",
        "./add-to-hosts.sh a.local ingress-nginx",
        "vagrant up",
    ])
    want = [
        "kubectl apply -f x.yaml",
        "settle",
        "browse \"$(kubectl get svc a -o jsonpath='http://{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}:8080')\"",
        "# this will fail:",
        "kubectl exec -i deploy/s -- sh <<'EOF' || expected\nhostname -i\nEOF",
        "kubectl get pods",
        "# browse to http://a.local/x, then",
        "browse http://a.local/x",
        "kubectl get secret x -o jsonpath='{.data}'",
        "hosts_add a.local ingress-nginx",
        "manual 'vagrant up'",
    ]
    assert got == want, "\n".join(got)
    print("ok")


if __name__ == "__main__":
    if "--test" in sys.argv:
        test()
        sys.exit()
    blocks = json.load(open(os.path.join(HERE, "blocks.json")))
    for chapter, chapter_blocks in blocks.items():
        path = os.path.join(ROOT, chapter, "try-it-now.sh")
        with open(path, "w") as f:
            f.write(generate(chapter, chapter_blocks))
        os.chmod(path, 0o755)
        print(path)
