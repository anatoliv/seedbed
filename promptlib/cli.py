"""promptlib — a personal library of model-tailored prompts.

    python3 -m promptlib list
    python3 -m promptlib build --id fix-bug-and-test --model claude-opus-5
    python3 -m promptlib copy fix-bug-and-test --model claude-opus-5
"""

from __future__ import annotations

import argparse
import json
import subprocess
import re
import sys
from datetime import date
from pathlib import Path

from . import builder, compare as compare_mod, match as match_mod
from .enhance import DEFAULT_BACKEND, EnhancerError, enhance
from .enhancer import (PRESETS, AUTH_MODES, EnhancerConfig, KEYCHAIN_SERVICE,
                       FALLBACK_KEYCHAIN_SERVICE, keychain_set, preset as find_preset)
from .guides import GuideCache, Model, load_registry, save_registry
from .store import CONTEXTS, DEFAULT_CONTEXT, FormatError, Library, Render, Seed
from .usage import Usage
from .variables import History, fill as fill_variables, find as find_variables

ROOT = Path(__file__).resolve().parent.parent
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")


def _fail(message: str) -> int:
    print(f"error: {message}", file=sys.stderr)
    return 1


def cmd_list(args, lib: Library, models: dict, cache: GuideCache) -> int:
    seeds = lib.seeds()
    if not seeds:
        print(f"no seeds yet — add one with: python3 -m promptlib new <id>")
        return 0
    hashes = {}
    for seed in seeds:
        context = "" if seed.context == DEFAULT_CONTEXT else f"  [{seed.context}]"
        print(f"{seed.id}  —  {seed.title or seed.body[:48]}{context}")
        for model in builder.targets_for(seed, models):
            if model not in hashes:
                hashes[model] = cache.guidance_for(models[model])[1]
            render = lib.render(seed.id, model)
            if render is None:
                state = "not built"
            elif render.is_current(seed, hashes[model]):
                state = f"current ({render.generated})"
            elif render.context != seed.context:
                # Name the specific cause. "Stale" alone sends you looking at the
                # seed text when nothing about the text changed.
                state = (f"STALE — built for {render.context}, "
                         f"prompt now says {seed.context}")
            else:
                state = "STALE — seed or guidance changed"
            print(f"    {model:<22} {state}")
    return 0


def cmd_json(args, lib: Library, models: dict, cache: GuideCache) -> int:
    """The library as JSON — what the macOS app reads instead of parsing files."""
    view = builder.library_view(lib, models, cache, Usage(args.root))
    view["history"] = History(args.root).as_dict()
    print(json.dumps(view, indent=None))
    return 0


def cmd_show(args, lib: Library, models: dict, cache: GuideCache) -> int:
    if args.model:
        render = lib.render(args.id, args.model)
        if render is None:
            return _fail(f"{args.id} has no render for {args.model} — build it first")
        print(render.body)
        # --record folds the usage bump into the same process as the read, so a
        # copy is one spawn rather than two.
        if getattr(args, "record", False):
            Usage(args.root).record(args.id, args.model)
    else:
        print(lib.seed(args.id).body)
    return 0


def cmd_copy(args, lib: Library, models: dict, cache: GuideCache) -> int:
    if args.live:
        rc = cmd_build(args, lib, models, cache)
        if rc:
            return rc
    render = lib.render(args.id, args.model)
    if render is None:
        return _fail(
            f"{args.id} has no render for {args.model}. Build it:\n"
            f"  python3 -m promptlib build --id {args.id} --model {args.model}"
        )
    seed = lib.seed(args.id)
    guide_hash = cache.guidance_for(models[args.model])[1]
    if not render.is_current(seed, guide_hash):
        print("warning: this render is stale (seed or guidance moved)", file=sys.stderr)
    try:
        subprocess.run(["pbcopy"], input=render.body, text=True, check=True)
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        return _fail(f"could not copy to the clipboard: {exc}")
    words = len(render.body.split())
    print(f"copied {args.id} for {args.model} ({words} words)")
    return 0


def cmd_build(args, lib: Library, models: dict, cache: GuideCache) -> int:
    if args.model and args.model not in models:
        return _fail(f"unknown model {args.model!r} — see models.toml")
    problems: list[str] = []
    pairs = builder.pending(
        lib, models, cache,
        seed_id=args.id, model_id=args.model,
        force=args.force, refresh_guides=args.refresh,
        problems=problems,
    )
    if problems and not args.allow_degraded:
        # Refusing is the honest default. A render written from "[guidance
        # unavailable]" is WORSE than the one already on disk, and it would be
        # stamped current, so the damage is invisible afterwards. Doing nothing
        # leaves a render that is merely stale, which is a state the app already
        # shows you.
        print("refusing to build: guidance could not be read", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print("The renders on disk were built with more guidance than a rebuild "
              "would have. Fix the source, or pass --allow-degraded.", file=sys.stderr)
        return 1
    if problems:
        print("WARNING: building on degraded guidance:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
    if not pairs:
        print("everything is up to date")
        return 0
    built = failed = 0
    for pair in pairs:
        print(f"building {pair.key} …", flush=True)
        try:
            builder.render_one(lib, pair, args.enhancer)
            built += 1
        except EnhancerError as exc:
            print(f"  failed: {exc}", file=sys.stderr)
            failed += 1
    print(f"built {built}, failed {failed}")
    return 1 if failed else 0


def cmd_fill(args, lib: Library, models: dict, cache: GuideCache) -> int:
    """Print a render with its placeholders filled in, and remember the values.

    One process does the substitution, the history write and the usage bump, so
    a fill-and-copy is a single spawn from the app.
    """
    render = lib.render(args.id, args.model)
    if render is None:
        return _fail(f"{args.id} has no render for {args.model} — build it first")

    values: dict[str, str] = {}
    for pair in args.set or []:
        name, sep, value = pair.partition("=")
        if not sep:
            return _fail(f"--set expects NAME=VALUE, got {pair!r}")
        values[name.strip()] = value
    known = set(find_variables(render.body))
    unknown = sorted(set(values) - known)
    if unknown:
        return _fail(f"{args.id}/{args.model} has no placeholder(s): {', '.join(unknown)}")

    print(fill_variables(render.body, values))
    History(args.root).record_all(values)
    if args.record:
        Usage(args.root).record(args.id, args.model)
    return 0


def cmd_vars(args, lib: Library, models: dict, cache: GuideCache) -> int:
    """The placeholders in one render, plus what has been entered for them."""
    render = lib.render(args.id, args.model)
    if render is None:
        return _fail(f"{args.id} has no render for {args.model}")
    names = find_variables(render.body)
    history = History(args.root)
    print(json.dumps({n: history.values(n) for n in names}))
    return 0


def cmd_save(args, lib: Library, models: dict, cache: GuideCache) -> int:
    """Create or update a seed from the library window.

    The body comes from a file, not an argument: prompts are multi-line and
    quoting them through a process boundary is a bug waiting to happen.
    """
    if not ID_RE.match(args.id):
        return _fail(f"{args.id!r} is not a usable id (a-z, 0-9, hyphens)")

    path = lib.prompts / f"{args.id}.md"
    existing = Seed.load(path) if path.is_file() else None

    body = existing.body if existing else ""
    if args.body_file:
        body = Path(args.body_file).read_text(encoding="utf-8").strip()
    if not body:
        return _fail("a prompt cannot be empty")

    unknown = [t for t in (args.target or []) if t not in models]
    if unknown:
        return _fail(f"unknown model(s): {', '.join(unknown)}")

    seed = Seed(
        id=args.id,
        body=body,
        category=args.category if args.category is not None
                 else (existing.category if existing else ""),
        title=args.title if args.title is not None else (existing.title if existing else ""),
        targets=args.target if args.target is not None else (existing.targets if existing else []),
        tags=args.tag if args.tag is not None else (existing.tags if existing else []),
        context=args.context if args.context is not None
                else (existing.context if existing else DEFAULT_CONTEXT),
        pinned=existing.pinned if existing else False,
    )
    if args.pinned:
        seed.pinned = True
    if args.no_pinned:
        seed.pinned = False

    lib.prompts.mkdir(parents=True, exist_ok=True)
    seed.write(path)
    # Editing the body invalidates every render of it; say so rather than
    # leaving the caller to discover it from a "stale" badge later.
    changed = existing is None or existing.body != seed.body
    print(f"{seed.id}: {'created' if existing is None else 'updated'}"
          f"{' — renders are now stale' if changed and existing else ''}")
    return 0


def cmd_match(args, lib: Library, models: dict, cache: GuideCache) -> int:
    """Find the prompt an ask means, by description rather than by name.

    Written for a caller that is not a person: the MCP server's `find_prompt`
    runs this. `--model` folds the winner's render into the same answer, so an
    agent asking "which prompt, and give me it" spends one process rather than
    two.
    """
    seeds = lib.seeds()
    if not seeds:
        return _fail("the library has no prompts yet")
    result = match_mod.search(
        args.ask,
        seeds,
        semantic=not args.no_semantic,
        limit=args.limit,
        config=EnhancerConfig.load(args.root),
    )

    render_body = ""
    render_state = ""
    if args.model and result.best:
        if args.model not in models:
            return _fail(f"unknown model {args.model!r} — see models.toml")
        render = lib.render(result.best.seed.id, args.model)
        if render is None:
            render_state = "not built"
        else:
            render_body = render.body
            guide_hash = cache.guidance_for(models[args.model])[1]
            render_state = "current" if render.is_current(result.best.seed, guide_hash) else "stale"
            if args.record:
                Usage(args.root).record(result.best.seed.id, args.model)

    if args.json:
        payload = result.as_dict()
        if args.model:
            payload["model"] = args.model
            payload["render"] = render_body
            payload["render_state"] = render_state
        print(json.dumps(payload))
        return 0

    if not result.matches:
        print(f"nothing in the library matches {args.ask!r}")
        return 1
    print(f"decided by: {result.decided_by}")
    for index, m in enumerate(result.matches):
        marker = "→" if index == 0 else " "
        print(f"{marker} {m.seed.id}  ({m.score:.2f} on {m.matched_on})"
              f"  {m.seed.title or ''}")
        if m.reason:
            print(f"    {m.reason}")
    if args.model:
        print()
        print(render_body if render_body else f"({args.model}: {render_state})")
    return 0


def cmd_compare(args, lib: Library, models: dict, cache: GuideCache) -> int:
    """A written comparison of how each model's version of a prompt differs."""
    try:
        lib.seed(args.id)
    except FileNotFoundError as exc:
        return _fail(str(exc))
    try:
        text, regenerated = compare_mod.build(
            lib, args.id, models, config=EnhancerConfig.load(args.root), force=args.force)
    except EnhancerError as exc:
        return _fail(str(exc))

    if args.json:
        _, mark, generated = compare_mod.load(lib, args.id)
        print(json.dumps({
            "id": args.id,
            "summary": text,
            "generated": generated,
            "state": compare_mod.state(lib, args.id, models),
            "regenerated": regenerated,
        }))
    else:
        print(text)
    return 0


def cmd_enhancer(args, lib: Library, models: dict, cache: GuideCache) -> int:
    """Show, change or test the model that builds prompts."""
    config = EnhancerConfig.load(args.root)

    if args.action == "presets":
        for p in PRESETS:
            print(f"{p.id:<16} {p.auth:<14} {p.name}")
        return 0

    if args.action == "show":
        if args.json:
            print(json.dumps({
                "auth": config.auth,
                "endpoint": config.endpoint,
                "model": config.model,
                "preset": config.preset,
                "timeout": config.timeout,
                "fallback_endpoint": config.fallback_endpoint,
                "fallback_model": config.fallback_model,
                # Whether a key exists, never the key itself.
                "has_key": bool(config.api_key),
                "has_fallback_key": bool(config.fallback_api_key),
                "summary": config.describe(),
                "problems": config.problems(),
                "presets": [
                    {"id": p.id, "name": p.name, "endpoint": p.endpoint,
                     "model": p.model, "auth": p.auth} for p in PRESETS
                ],
                "auth_modes": AUTH_MODES,
            }))
            return 0
        print(f"enhancer: {config.describe()}")
        if config.has_fallback:
            print(f"fallback: {config.fallback_model} at {config.fallback_endpoint}")
        for problem in config.problems():
            print(f"  problem: {problem}", file=sys.stderr)
        return 0

    if args.action == "set":
        if args.preset:
            chosen = find_preset(args.preset)
            if chosen is None:
                return _fail(f"unknown preset {args.preset!r} — see `enhancer presets`")
            config.preset = chosen.id
            config.auth = chosen.auth
            config.endpoint = chosen.endpoint
            config.model = chosen.model or config.model
        if args.auth:
            if args.auth not in AUTH_MODES:
                return _fail(f"auth must be one of: {', '.join(AUTH_MODES)}")
            config.auth = args.auth
        if args.endpoint is not None:
            config.endpoint = args.endpoint
        if args.model is not None:
            config.model = args.model
        if args.timeout is not None:
            config.timeout = args.timeout
        if args.fallback_endpoint is not None:
            config.fallback_endpoint = args.fallback_endpoint
        if args.fallback_model is not None:
            config.fallback_model = args.fallback_model
        # Keys go to the Keychain, never to the config file, and never echoed.
        if args.key is not None:
            keychain_set(KEYCHAIN_SERVICE, args.key)
        if args.fallback_key is not None:
            keychain_set(FALLBACK_KEYCHAIN_SERVICE, args.fallback_key)

        config.save()
        print(f"enhancer: {config.describe()}")
        for problem in config.problems():
            print(f"  problem: {problem}", file=sys.stderr)
        return 0

    if args.action == "test":
        problems = config.problems()
        if problems:
            for problem in problems:
                print(f"problem: {problem}", file=sys.stderr)
            return 1
        try:
            out = enhance("say ok", "Test Model", "Answer with a single short line.",
                          config=config)
        except EnhancerError as exc:
            return _fail(str(exc))
        print(f"ok — {config.describe()}")
        print(f"  replied: {out.splitlines()[0][:80] if out else '(empty)'}")
        return 0

    if args.action in {"login", "logout", "whoami"}:
        return _codex_action(args)

    return _fail(f"unknown action {args.action!r}")


def _codex_action(args) -> int:
    """Sign in to ChatGPT, sign out, or say who is signed in.

    Kept out of `cmd_enhancer` because it is the only part of the enhancer that
    opens a browser and listens on a port, and that is worth reading on its own.
    """
    from . import codex_oauth

    if args.action == "logout":
        codex_oauth.logout()
        print("signed out of ChatGPT; the stored tokens are gone")
        return 0

    if args.action == "whoami":
        state = codex_oauth.status()
        if not state["signed_in"]:
            print("not signed in — run: python3 -m promptlib enhancer login")
            return 1
        who = state["email"] or "(no email in the token)"
        plan = f", {state['plan']} plan" if state["plan"] else ""
        fresh = "needs refresh" if state["needs_refresh"] else f"{state['expires_in']}s left"
        print(f"signed in as {who}{plan} ({fresh})")
        return 0

    if not codex_oauth.port_is_free():
        return _fail(
            f"port {codex_oauth.CALLBACK_PORT} is in use. The authorization "
            "server allow-lists that exact port, so it cannot be changed — "
            "close whatever is holding it and try again.")

    print("Opening your browser to sign in to ChatGPT.")
    print(f"Waiting for the callback on 127.0.0.1:{codex_oauth.CALLBACK_PORT} "
          f"(up to {codex_oauth.LOGIN_TIMEOUT}s)…")
    try:
        claims = codex_oauth.login()
    except codex_oauth.CodexAuthError as exc:
        return _fail(str(exc))
    who = claims.email or "(no email in the token)"
    plan = f", {claims.plan} plan" if claims.plan else ""
    print(f"signed in as {who}{plan}")
    print("Set the enhancer to use it with: "
          "python3 -m promptlib enhancer set --preset openai-chatgpt")
    return 0


def cmd_model(args, lib: Library, models: dict, cache: GuideCache) -> int:
    """Add, change or remove a target model in models.toml."""
    path = args.root / "models.toml"

    if args.action == "remove":
        if args.id not in models:
            return _fail(f"no model named {args.id!r}")
        # Renders for a removed model stay on disk on purpose: re-adding it
        # should not cost another round of LLM calls.
        del models[args.id]
        save_registry(path, models)
        print(f"{args.id}: removed (its renders are kept)")
        return 0

    if args.action == "add" and args.id in models:
        return _fail(f"{args.id} already exists — use `model set`")
    if args.action == "set" and args.id not in models:
        return _fail(f"no model named {args.id!r} — use `model add`")

    existing = models.get(args.id)
    models[args.id] = Model(
        id=args.id,
        name=args.name or (existing.name if existing else args.id),
        family=args.family if args.family is not None else (existing.family if existing else ""),
        guides=args.guide if args.guide is not None else (existing.guides if existing else []),
        notes=args.notes if args.notes is not None else (existing.notes if existing else ""),
    )
    save_registry(path, models)
    print(f"{args.id}: {'added' if existing is None else 'updated'}")
    return 0


def cmd_remove(args, lib: Library, models: dict, cache: GuideCache) -> int:
    """Delete a prompt, and by default everything generated from it."""
    path = lib.prompts / f"{args.id}.md"
    if not path.is_file():
        return _fail(f"no prompt named {args.id!r}")

    removed = [path]
    if not args.keep_renders:
        for model_id in models:
            render = lib.render_path(args.id, model_id)
            if render.is_file():
                removed.append(render)
        summary = args.root / "comparisons" / f"{args.id}.md"
        if summary.is_file():
            removed.append(summary)

    for target in removed:
        target.unlink()
    print(f"{args.id}: removed ({len(removed)} file{'s' if len(removed) != 1 else ''})")
    return 0


def cmd_pin(args, lib: Library, models: dict, cache: GuideCache) -> int:
    """Pinning lives in the seed file, so it travels with the library."""
    seed = lib.seed(args.id)
    seed.pinned = not seed.pinned if args.toggle else not args.off
    seed.write(lib.prompts / f"{seed.id}.md")
    print(f"{seed.id}: {'pinned' if seed.pinned else 'unpinned'}")
    return 0


def cmd_serve(args, lib: Library, models: dict, cache: GuideCache) -> int:
    from .server import serve

    if args.open:
        subprocess.Popen(["open", f"http://127.0.0.1:{args.port}"])
    serve(args.root, port=args.port, enhancer=args.enhancer)
    return 0


def cmd_guides(args, lib: Library, models: dict, cache: GuideCache) -> int:
    """Re-fetch every guidance source, and FAIL if any of them could not be read.

    This used to print the error and return 0, which meant a vendor doc going
    404 was invisible to anything calling it: the app's "rebuild everything
    stale, re-pulling guidance first" would refresh, get "[guidance
    unavailable]", and rebuild every render for that model on less input than it
    already had. A refresh that half worked is not a success.
    """
    chosen = [models[args.model]] if args.model else list(models.values())
    failures: list[str] = []
    for model in chosen:
        if not model.guides:
            print(f"{model.id}: no external sources (registry note only)")
            continue
        for source in model.guides:
            try:
                _, fetched = cache.fetch(source, force=True)
            except (RuntimeError, FileNotFoundError) as exc:
                print(f"{model.id}: {exc}", file=sys.stderr)
                failures.append(f"{model.id}: {source}")
                continue
            print(f"{model.id}: {'fetched' if fetched else 'read'} {source}")
    if failures:
        print(f"\n{len(failures)} guidance source(s) could not be read:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        print("Renders built now would use less guidance than the ones they replace. "
              "Fix the source, or build with --allow-degraded if you accept that.",
              file=sys.stderr)
        return 1
    return 0


def cmd_rename(args, lib: Library, models: dict, cache: GuideCache) -> int:
    """Give a prompt a different id, and take everything named after it along.

    A prompt's id is its filename, the `id` in its own frontmatter, the filename
    of every render, the `seed` in each of those renders' provenance, the name of
    its comparison summary, and its key in the local usage counts. Six places, so
    renaming by hand means renaming five of them and discovering the sixth later.
    Until this existed there was no rename at all: a seed scaffolded as
    `new-prompt-3` and titled "Loop" kept that id permanently, and three of them
    had accumulated seven uses between them.

    Deliberately not a re-render. The id is not an input to the enhancer — only
    the body, the guidance and the context are, and `seed_hash` is computed from
    the seed's content — so every render stays valid and current across a rename.
    Re-rendering here would spend an LLM call per model to produce the same text.
    """
    old, new = args.id, args.new_id

    # ID_RE, not a second rule of my own: an id this module would refuse to
    # create is one it should refuse to rename to.
    if not ID_RE.match(new):
        return _fail(f"{new!r} is not a usable id: lowercase letters, digits and "
                     "hyphens, starting with a letter or digit")
    source = lib.prompts / f"{old}.md"
    if not source.is_file():
        return _fail(f"no prompt named {old!r}")
    target = lib.prompts / f"{new}.md"
    if target.exists():
        return _fail(f"{new!r} already exists — pick another id or remove that one")

    # Every move is computed before any is made. A rename that half-happens
    # leaves renders orphaned under a name nothing points at, and the library
    # then reports them as missing rather than as stranded.
    moves: list[tuple[Path, Path]] = [(source, target)]
    for model_id in models:
        render = lib.render_path(old, model_id)
        if render.is_file():
            moves.append((render, lib.render_path(new, model_id)))
    summary = args.root / "comparisons" / f"{old}.md"
    if summary.is_file():
        moves.append((summary, args.root / "comparisons" / f"{new}.md"))

    clashes = [dst for _, dst in moves if dst.exists()]
    if clashes:
        return _fail("refusing to overwrite: "
                     + ", ".join(str(c.relative_to(args.root)) for c in clashes))

    for src, dst in moves:
        dst.parent.mkdir(parents=True, exist_ok=True)
        src.rename(dst)

    # The id lives inside the files too, not only in their names.
    seed = Seed.load(target)
    seed.id = new
    seed.write(target)
    for _, dst in moves[1:]:
        if dst.parent.name == "comparisons":
            continue
        render = Render.load(dst)
        # `seed_id`, not `seed`. The frontmatter key is "seed" and the field is
        # not, and Render is a plain dataclass — assigning `render.seed` creates
        # a new attribute, write() ignores it, and the rename reports success
        # having changed nothing inside the file. Caught by the test, not by
        # reading this.
        render.seed_id = new
        render.write(dst)

    usage = Usage(args.root)
    usage.load()
    if old in usage.data:
        usage.data[new] = usage.data.pop(old)
        usage.save()

    print(f"{old} → {new} ({len(moves)} file{'s' if len(moves) != 1 else ''} moved)")
    return 0


def cmd_new(args, lib: Library, models: dict, cache: GuideCache) -> int:
    path = lib.prompts / f"{args.id}.md"
    if path.exists():
        return _fail(f"{path} already exists")
    lib.prompts.mkdir(parents=True, exist_ok=True)
    Seed(
        id=args.id,
        title=args.title or args.id.replace("-", " "),
        targets=[],
        tags=[],
        body=args.body or "describe the task in one line",
        context=args.context,
    ).write(path)
    print(f"created {path.relative_to(ROOT)} — edit it, then build")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="promptlib", description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="library root")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("list", help="seeds, targets and staleness")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("json", help="the whole library as JSON (for the macOS app)")
    p.set_defaults(func=cmd_json)

    p = sub.add_parser("show", help="print a seed or a render")
    p.add_argument("id")
    p.add_argument("--model")
    p.add_argument("--record", action="store_true", help="count this as a use")
    p.set_defaults(func=cmd_show)

    p = sub.add_parser("fill", help="print a render with its placeholders filled")
    p.add_argument("id")
    p.add_argument("--model", required=True)
    p.add_argument("--set", action="append", metavar="NAME=VALUE",
                   help="repeatable; unfilled placeholders are left standing")
    p.add_argument("--record", action="store_true", help="count this as a use")
    p.set_defaults(func=cmd_fill)

    p = sub.add_parser("vars", help="placeholders in a render, with value history")
    p.add_argument("id")
    p.add_argument("--model", required=True)
    p.set_defaults(func=cmd_vars)

    p = sub.add_parser("save", help="create or update a seed")
    p.add_argument("id")
    p.add_argument("--title")
    p.add_argument("--body-file", help="file holding the prompt text")
    p.add_argument("--target", action="append", help="repeatable; replaces the list")
    p.add_argument("--tag", action="append", help="repeatable; replaces the list")
    p.add_argument("--category", help="grouping used by search and filters")
    p.add_argument("--pinned", action="store_true")
    p.add_argument("--no-pinned", action="store_true")
    p.add_argument("--context", choices=sorted(CONTEXTS),
                   help="where the prompt gets pasted: an agent with the repo "
                        "open, or a chat window with one snippet. Changing it "
                        "restages this prompt's renders.")
    p.set_defaults(func=cmd_save)

    p = sub.add_parser("match", help="find a prompt by description, not by name")
    p.add_argument("ask", help="what you are looking for, in your own words")
    p.add_argument("--json", action="store_true", help="machine-readable, for the MCP server")
    p.add_argument("--limit", type=int, default=5, help="how many candidates to return")
    p.add_argument("--no-semantic", action="store_true",
                   help="lexical only: never ask the enhancer to break a tie")
    p.add_argument("--model", default="", help="also return this model's render of the winner")
    p.add_argument("--record", action="store_true",
                   help="count this as a use of the winning prompt (with --model)")
    p.set_defaults(func=cmd_match)

    p = sub.add_parser("compare", help="how each model's version of a prompt differs")
    p.add_argument("id")
    p.add_argument("--force", action="store_true", help="regenerate even if current")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_compare)

    p = sub.add_parser("enhancer", help="the model that BUILDS prompts")
    p.add_argument("action",
                   choices=["show", "set", "test", "presets",
                            "login", "logout", "whoami"])
    p.add_argument("--preset", help="fills endpoint, model and auth mode")
    p.add_argument("--auth", help=f"one of: {', '.join(AUTH_MODES)}")
    p.add_argument("--endpoint")
    p.add_argument("--model")
    p.add_argument("--key", help="stored in the Keychain, never in a file")
    p.add_argument("--timeout", type=int)
    p.add_argument("--fallback-endpoint")
    p.add_argument("--fallback-model")
    p.add_argument("--fallback-key")
    p.add_argument("--json", action="store_true", help="machine-readable, key values omitted")
    p.set_defaults(func=cmd_enhancer)

    p = sub.add_parser("model", help="add, change or remove a target model")
    p.add_argument("action", choices=["add", "set", "remove"])
    p.add_argument("id")
    p.add_argument("--name")
    p.add_argument("--family")
    p.add_argument("--guide", action="append", help="repeatable; URL or local path")
    p.add_argument("--notes", help="how to prompt this model; part of its guidance")
    p.set_defaults(func=cmd_model)

    p = sub.add_parser("remove", help="delete a prompt and what was generated from it")
    p.add_argument("id")
    p.add_argument("--keep-renders", action="store_true",
                   help="delete the prompt but leave its rendered versions on disk")
    p.set_defaults(func=cmd_remove)

    p = sub.add_parser("pin", help="pin a prompt to the top of the list")
    p.add_argument("id")
    p.add_argument("--off", action="store_true", help="unpin instead")
    p.add_argument("--toggle", action="store_true", help="flip the current state")
    p.set_defaults(func=cmd_pin)

    p = sub.add_parser("copy", help="put a render on the clipboard")
    p.add_argument("id")
    p.add_argument("--model", required=True)
    p.add_argument("--live", action="store_true", help="re-render before copying")
    p.add_argument("--enhancer", default=DEFAULT_BACKEND)
    p.add_argument("--force", action="store_true")
    p.add_argument("--refresh", action="store_true")
    p.set_defaults(func=cmd_copy)

    p = sub.add_parser("build", help="render seeds for their target models")
    p.add_argument("--id")
    p.add_argument("--model")
    p.add_argument("--force", action="store_true", help="rebuild even if current")
    p.add_argument("--refresh", action="store_true", help="re-fetch guidance first")
    p.add_argument("--allow-degraded", action="store_true",
                   help="build even when a guidance source could not be read")
    p.add_argument("--enhancer", default=DEFAULT_BACKEND)
    p.set_defaults(func=cmd_build)

    p = sub.add_parser("serve", help="local web UI: list, dropdown, copy")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--open", action="store_true", help="open a browser too")
    p.add_argument("--enhancer", default=DEFAULT_BACKEND)
    p.set_defaults(func=cmd_serve)

    p = sub.add_parser("guides", help="refresh cached prompting guidance")
    p.add_argument("action", choices=["fetch"])
    p.add_argument("--model")
    p.set_defaults(func=cmd_guides)

    p = sub.add_parser("rename", help="give a prompt a different id")
    p.add_argument("id")
    p.add_argument("new_id", metavar="new-id")
    p.set_defaults(func=cmd_rename)

    p = sub.add_parser("new", help="scaffold a seed")
    p.add_argument("id")
    p.add_argument("--title", default="")
    p.add_argument("--body", default="")
    p.add_argument("--context", choices=sorted(CONTEXTS), default=DEFAULT_CONTEXT)
    p.set_defaults(func=cmd_new)

    args = parser.parse_args(argv)
    root = args.root
    try:
        models = load_registry(root / "models.toml")
    except FileNotFoundError:
        return _fail(f"no models.toml in {root}")
    if args.command in {"copy", "show"} and getattr(args, "model", None) and args.model not in models:
        return _fail(f"unknown model {args.model!r} — see models.toml")
    try:
        return args.func(args, Library(root), models, GuideCache(root))
    except (FormatError, FileNotFoundError) as exc:
        return _fail(str(exc))


if __name__ == "__main__":
    raise SystemExit(main())
