# Plan 001: Announce every published release in Discord with an @everyone ping

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 1fd219d..HEAD -- .github/workflows`
> This plan only adds a new file under `.github/workflows/`. If that directory
> already contains a workflow that posts to Discord, STOP (see STOP conditions).

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (a new, isolated workflow; it cannot affect the app or its release build)
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `1fd219d`, 2026-10-02

## Why this matters

AniView is released by hand (`gh release create` — see `README.md` → "Release") and its users gather in a Discord
server (README links it). Today nobody is told a release exists unless they open the app and its update check
fires. A workflow that posts each published release to a Discord channel, pinging `@everyone`, closes that gap
without changing how releases are made: it only reacts to a release being published.

## Current state

- `.github/` contains only `ISSUE_TEMPLATE/` and `pull_request_template.md`. There is **no** `.github/workflows/`
  directory yet. The repo is public (`ebrahimHakimuddin/aniview`, default branch `main`).
- Releases are made manually from a developer machine (the signing key `android/key.properties` and
  `android/app/aniview-release.jks` are gitignored and never in CI):

  ```sh
  git tag v2.2.1 && git push origin main v2.2.1
  gh release create v2.2.1 build/app/outputs/flutter-apk/app-*-release.apk --title v2.2.1 --notes-file /tmp/aniview-v2.2.1-notes.md
  ```

  So the release's title is the tag (e.g. `v2.2.1`) and its body is a short notes file.
- Discord is where the community is: `README.md` line 5 links `https://discord.gg/TXkEgGK9cp`.
- The app's accent colour is cyan `#01C4FA` (`lib/ui.dart`, `const seed = Color(0xFF01C4FA)`); as an integer that is
  `115962`.
- Commit-message style in this repo is a sentence-case imperative with no prefix and **no trailers** — e.g.
  `Lead the episodes section with its tabs and tidy episode row actions`. Do not add `Co-Authored-By` or any
  session/tool trailer to commits.

## Human prerequisites (the executor cannot do these — list them in your final report)

1. In Discord: Server Settings → Integrations → Webhooks → New Webhook → choose the announcements channel →
   Copy Webhook URL. The channel must let that webhook mention `@everyone` (channel permission "Mention
   @everyone, @here and All Roles").
2. In GitHub: Settings → Secrets and variables → Actions → New repository secret named exactly
   `DISCORD_WEBHOOK_URL`, value = the webhook URL. (Or `gh secret set DISCORD_WEBHOOK_URL`.)

**Never** paste the webhook URL into the workflow file, a commit message, a plan, an issue or a chat. It is a
credential: anyone holding it can post to the channel. If it is ever exposed, delete the webhook in Discord and
create a new one.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Parse the workflow YAML | `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release-announce.yml'))"` | exit 0, no output |
| Lint the workflow (only if installed) | `actionlint .github/workflows/release-announce.yml` | exit 0 (skip if `actionlint` is not installed) |
| Build the payload locally | see Step 2 | prints valid JSON; `jq -e` exits 0 |
| Secret not inlined | `grep -n "discord.com/api/webhooks" .github/workflows/release-announce.yml` | no output (exit 1) |

## Scope

**In scope** (the only files you should modify):
- `.github/workflows/release-announce.yml` (create)

**Out of scope** (do NOT touch):
- The app (`lib/`, `android/`, `pubspec.yaml`) — this workflow never builds or signs anything.
- Any attempt to build or upload APKs from CI: the signing key lives only on the maintainer's machine. Do not add
  build steps or signing secrets.
- `README.md` (documenting the secret is a follow-up, see Maintenance notes).
- Third-party actions of any kind. Use only `curl`, `jq` and `gh`, which are preinstalled on `ubuntu-latest`.

## Git workflow

- Branch: `advisor/001-announce-releases` (no branch convention is evident in the repo).
- One commit, message e.g. `Announce published releases in Discord`. No trailers.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create the workflow

Create `.github/workflows/release-announce.yml` with exactly this content:

```yaml
name: Announce release

# Posts a published release to Discord. The secret DISCORD_WEBHOOK_URL is the channel's webhook (see plans/001).
on:
  release:
    # `released` fires when a release is published (not for drafts or pre-releases).
    types: [released]
  workflow_dispatch:
    inputs:
      ping:
        description: Ping @everyone (leave off for a test post of the latest release)
        type: boolean
        default: false

permissions:
  contents: read

jobs:
  discord:
    runs-on: ubuntu-latest
    steps:
      - name: Post to Discord
        env:
          WEBHOOK: ${{ secrets.DISCORD_WEBHOOK_URL }}
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          # Empty on a manual run, which announces the latest release instead.
          TAG: ${{ github.event.release.tag_name }}
          PING: ${{ github.event_name == 'release' || inputs.ping }}
        run: |
          if [ -z "$WEBHOOK" ]; then
            echo "::notice::DISCORD_WEBHOOK_URL isn't set, so nothing was posted"
            exit 0
          fi
          gh release view ${TAG:+"$TAG"} --repo "$REPO" --json tagName,name,body,url > release.json
          # The notes go in an embed, which never pings; only the message text can mention @everyone.
          jq -n --slurpfile release release.json --argjson ping "$PING" '
            $release[0] as $r
            | {
                content: ((if $ping then "@everyone " else "" end) + "**AniView " + $r.tagName + "** is out"),
                allowed_mentions: { parse: (if $ping then ["everyone"] else [] end) },
                embeds: [{
                  title: ($r.name // $r.tagName),
                  url: $r.url,
                  description: (($r.body // "") | .[0:1500]),
                  color: 115962
                }]
              }' > payload.json
          curl --fail-with-body --silent --show-error --retry 3 \
            -H 'Content-Type: application/json' -d @payload.json "$WEBHOOK"
```

Why it is written this way (do not "simplify" these away):
- The release title/notes are passed through `gh release view` and `jq`, never interpolated into the shell script
  with `${{ }}`. Release notes are free text; `${{ github.event.release.body }}` inside `run:` would be a script
  injection hole.
- `allowed_mentions.parse` lists only `everyone`, so a `@role` or `@user` typed in the notes cannot ping anyone.
- The missing-secret branch exits 0 so forks (which have no secret) don't show a red workflow.
- No third-party actions, so there is no supply-chain surface.

**Verify**: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release-announce.yml'))"` → exit 0, no
output. If `actionlint` is installed, `actionlint .github/workflows/release-announce.yml` → exit 0.

### Step 2: Check the payload logic locally

Run the same `jq` program against a sample release that contains a hostile-looking body:

```sh
cat > /tmp/release.json <<'EOF'
{"tagName":"v9.9.9","name":"v9.9.9","url":"https://github.com/example/aniview/releases/tag/v9.9.9","body":"Fixes things. @everyone @here <@123> \"quotes\" and $(echo no)"}
EOF
PING=true
jq -n --slurpfile release /tmp/release.json --argjson ping "$PING" '
  $release[0] as $r
  | {
      content: ((if $ping then "@everyone " else "" end) + "**AniView " + $r.tagName + "** is out"),
      allowed_mentions: { parse: (if $ping then ["everyone"] else [] end) },
      embeds: [{ title: ($r.name // $r.tagName), url: $r.url, description: (($r.body // "") | .[0:1500]), color: 115962 }]
    }' | tee /tmp/payload.json | jq -e '.content == "@everyone **AniView v9.9.9** is out" and .allowed_mentions.parse == ["everyone"] and .embeds[0].color == 115962'
```

**Verify**: prints `true` and exits 0. Then re-run with `PING=false` and confirm
`jq -e '.content == "**AniView v9.9.9** is out" and .allowed_mentions.parse == []' /tmp/payload.json` prints `true`.
(Copy the program from the workflow if you edited it, so you test the real thing.)

### Step 3: Confirm no secret or webhook URL is in the file

**Verify**: `grep -n "discord.com/api/webhooks" .github/workflows/release-announce.yml` → no output (exit 1), and
`grep -n "DISCORD_WEBHOOK_URL" .github/workflows/release-announce.yml` shows only the `secrets.` reference and the
comment/notice text.

### Step 4: Commit

```sh
git add .github/workflows/release-announce.yml
git commit -m "Announce published releases in Discord"
```

**Verify**: `git status --short` → clean; `git show --stat HEAD` lists only `.github/workflows/release-announce.yml`.

## Test plan

The workflow itself can only be exercised on GitHub, after the human prerequisites are done and the file is on
`main` (workflow files only run from the default branch). Local checks are Steps 1–3. After merge, tell the
maintainer to:

1. Run Actions → "Announce release" → "Run workflow" with **ping off**. Expect one message in the channel with the
   latest release's notes and no mention. (Point the secret at a private test channel first if they want zero risk of a
   stray ping.)
2. Publish the next real release; expect one `@everyone` message.

## Done criteria

ALL must hold:

- [ ] `.github/workflows/release-announce.yml` exists and parses as YAML (Step 1 command exits 0)
- [ ] Step 2's two payload checks both print `true`
- [ ] `grep -n "discord.com/api/webhooks" .github/workflows/release-announce.yml` returns no matches
- [ ] `git status --short` shows no modified files other than the one committed file (i.e. clean after the commit)
- [ ] `plans/README.md` status row updated
- [ ] Final report lists the two human prerequisites and that nothing was run on GitHub

## STOP conditions

Stop and report back (do not improvise) if:

- `.github/workflows/` already exists with a workflow that posts to Discord — this plan would duplicate it.
- `jq` is not available locally (then say so; the logic in Step 2 is unverified).
- You feel a need to build or sign APKs in CI, add a third-party action, or change the app — all out of scope.
- The payload check in Step 2 fails twice after a fix attempt.

## Maintenance notes

- If a future workflow creates releases with the default `GITHUB_TOKEN`, GitHub will **not** trigger this workflow
  for them (events created by that token don't start other workflows). Creating releases with `gh` from a
  developer machine, as now, is unaffected.
- Discord limits: message text 2000 characters, embed description 4096. The workflow truncates notes to 1500.
  If notes are routinely longer, link to the release page instead of truncating.
- Follow-up deferred: a short "Release" subsection in `README.md` documenting the `DISCORD_WEBHOOK_URL` secret.
- Reviewer: scrutinize that the release text never reaches the shell through `${{ }}` and that `allowed_mentions`
  stays restrictive.
