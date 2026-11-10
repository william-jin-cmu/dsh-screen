# dsh-screen

Lets a DeepSeek Harness agent see what is on your screen. It reads the text of the window you are looking at through the macOS Accessibility API, on this computer, and can optionally remember what you looked at so the agent can answer "what was I doing".

macOS only.

## What the agent gets

| Tool | What it does | Available |
| --- | --- | --- |
| `screen_now` | The app, title, URL, selected text and text of the window in front | Always |
| `screen_timeline` | What you did, by app and window, over a period | With `memory` on |
| `screen_search` | Full-text search over remembered screen text | With `memory` on |
| `screen_get` | The full text of one remembered entry | With `memory` on |

The `/screen` command shows which permissions are granted and whether screen memory is on.

## Install

Requires DSH `>=0.2.1-rc.5 <0.3.0` and Node.js 22.19 or later.

```sh
dsh plugin --profile web add ./dsh-screen-0.1.0.tgz
```

In the desktop app, use Plugins > Add plugin with the path of the tarball instead.

The helper runs as a child of DSH, so macOS asks for **Accessibility** for the app DSH runs in: your terminal for `dsh web`, or the DSH desktop app. Screen Recording is only needed for screenshots.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `memory` | `false` | Sample the window in front every few seconds and keep its text, in `$DSH_HOME/screen/screen.db` |
| `intervalSeconds` | `5` | How often screen memory samples |
| `retentionDays` | `30` | How long screen memory keeps what it recorded |
| `ignoreApps` | DSH's own windows | When one of these is in front, the window behind it is read instead |
| `excludeApps` | Password managers | Bundle ids that are never read or remembered |

## Privacy

Nothing leaves the computer except what the agent puts in a model request after calling one of the tools. Screen memory is off until you turn it on, and the apps in `excludeApps` are never read.

## Build

```sh
pnpm install
pnpm run pack   # dist/, bin/ and dsh-screen-0.1.0.tgz
```
