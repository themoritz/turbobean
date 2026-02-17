<p align="center">
  <img src="src/assets/img/logo.png" alt="Logo" height=100>
</p>
<h2 align="center">TurboBean</h2>

An implementation of [Beancount](https://github.com/beancount/beancount) with
a focus on speed and ease of use.

![](docs/screenshot.png)

I love Beancount, but my journal is growing and the existing ecosystem with
its Python based implementation is too slow. Also, there's no easy to set up
LSP which prevents me from editing my .bean files in Vim. This implementation
aims to fix both.

The philosopy is:
* you download a single small binary that doesn't have any dependencies and
  just works
* it contains the core Beancount logic wrapped as simple commands and
  processing is very fast
* provides a good LSP and formatter out of the box so all editors are supported
* provides a simple/practical Web UI for basic needs
* plugins are written in Lua
* interop with other tools/languages works via templating (input) and protobuf
  (output)

## Features

- [ ] Core
  - [ ] Automatic PnL Postings
- [x] Speed (processes huge files instantly)
- [x] LSP Server
  - [x] Jump to account open
  - [x] Hover account (before + after balance)
  - [x] Auto completion (accounts, tags, links)
  - [x] Highlight account
  - [x] Highlight tags + links
  - [x] Syntax highlighting via semantic tokens
  - [x] Rename account
  - [ ] Rename tags and links
  - [ ] Display interpolated values inline
- [x] Web UI (similar to [fava](https://github.com/beancount/fava))
  - [x] File Watcher (instant reloads)
    - [x] MacOS
    - [ ] Windows
    - [ ] Linux
  - [x] Journal
  - [x] Balance Sheet
  - [x] Income Statement
  - [ ] Filter language
  - [ ] Display errors
- [ ] Lua Plugins
- [ ] Pretty formatter
- [ ] Protobuf Output

#### Not Planned (for now, might change my mind)

- Query Language
- Importing data (use templates in your favorite language + formatter)
- Price fetching (same)

## Installation

### Download Binary

Go to the [latest
release](https://github.com/themoritz/turbobean/releases/latest), pick your CPU
architecture and operating system, then download and extract the tarball/zip to
somewhere on your `$PATH`.

### Building from Source

Install the [Zig compiler](https://ziglang.org/). Then (assuming you have a Unix
system and `~/.local/bin` is on your `$PATH`):

```bash
zig build --release=safe -Dembed-static --prefix ~/.local
```

## Use

* Run `turbobean serve <project_root>.bean` to launch a server that serves the
  Web UI.
* Navigate to `http://localhost:8080` in your browser.
* Press the `g` key to fuzzy-navigate (e.g. balance sheet, income statement, journal).

## Editor Setup

Any editor that supports LSP should work. You just need to tell it to use
the `turbobean lsp` command to start the server (it always uses stdio for
transport).

For projects spanning multiple files, you can define the root .bean file as
follows: Create a `turbobean.config` file in the workspace folder (e.g., next
to your `.git` folder) with the following content:

```config
root = main.bean
```

### neovim

Put this into your nvim-lspconfig's `config` function:

```lua
    local lspconfig = require 'lspconfig'
    require('lspconfig.configs').turbobean = {
      default_config = {
        cmd = {
          'bash',
          '-c',
          'turbobean lsp 2> >(tee turbobean.log >&2)',
        },
        filetypes = { 'beancount', 'bean' },
        root_dir = require('lspconfig.util').root_pattern 'turbobean.config',
      },
    }
    lspconfig.turbobean.setup {}

```

Disable treesitter since it interferes with syntax highlighting coming from
the LSP's semantic tokens feature:

```lua
return {
  'nvim-treesitter/nvim-treesitter',
  opts = {
    highlight = {
      enable = true,
      disable = { 'beancount' },
    },
  },
}
```

Maybe there's a way we can keep treesitter enabled and then overwrite with
the sematic tokens info?

### VSCode

Use the extension in this repo:

```bash
cd vscode
npm i
code .
```

Then press `F5`, or go to debugging and click "Run Extension".

### Emacs

Minimal Emacs 30 config based on eglot:

```lisp
;; 1. Define the major mode
(define-derived-mode beancount-mode prog-mode "Beancount"
  "Major mode for editing Beancount files."
  (eglot-semtok-font-lock-init)  ; For semantic tokens
  (eglot-ensure))   ; start Eglot automatically

(add-to-list 'auto-mode-alist '("\\.bean\\'" . beancount-mode))

;; 2. Tell Eglot how to start your server
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(beancount-mode . ("~/.local/bin/turbobean" "lsp"))))

;; 3. Tell Eglot to use semantic tokens
;; (from https://codeberg.org/harald/eglot-supplements/src/branch/main/eglot-semtok.el)
(require 'eglot-semtok "~/.emacs.d/eglot-semtok.el")
(with-eval-after-load 'eglot
  ;; start eglot-semtok once we have a server connection
  (add-hook 'eglot-connect-hook 'eglot-semtok-on-connected))

```

### Helix

In your `~/.config/helix/languages.toml`:

```toml
[language-server.turbobean]
command = "turbobean"
args = ["lsp"]

[[language]]
name = "bean"
scope = "source.bean"
grammar = "beancount"
file-types = ["bean"]
language-servers = ["turbobean"]
```

I don't know how to get Helix to use the semantic tokens feature so I copied
the existing Beancount highlight queries (from
[https://github.com/helix-editor/helix/blob/master/runtime/queries/beancount/highlights.scm]()
to `~/.config/helix/runtime/queries/bean/highlights.scm`).

## Compatibility

Aims to be compatible with Beancount as much as possible, following some ideas
from [Beancount Vnext:
Goals
& Design](https://docs.google.com/document/d/1qPdNXaz5zuDQ8M9uoZFyyFis7hA0G55BEfhWhrVBsfc/edit?tab=t.0),
notably [Beancount - Vnext: Booking Rules
Redesign](https://docs.google.com/document/d/1H0UDD1cKenraIMe40PbdMgnqJdeqI6yKv0og51mXk-0/view#).
This is currently implemented in a non-backwards-compatible way.

#### Known Incompatibilities

* The balancing algorithm doesn't automatically insert multiple postings to the
  same account. For example, the following transaction doesn't balance:

  ```beancount
  2023-10-30 * "Cash Distribution"
    Assets:Cash           -92.08 EUR
    Assets:Cash          -794.49 USD
    Expenses:Trips:Car    600.00 USD
    Expenses:Food:Out
  ```

  You have to insert a second `Expenses:Food:Out` posting so that the USD and 
  EUR amounts can be put there. This is so that the editor can properly show 
  the inserted amounts inline.

* The booking rules design is not fully formed yet. Right now there is the
  distinction between "booked" and "plain" accounts. Commodities can only be
  bought in "booked" accounts, which is not great but simplifies implementation.

## Developing

### Prerequisites

* Install the [Zig compiler](https://ziglang.org/) (project currently uses 0.15.2).
* I recommend [ZLS](https://zigtools.org/zls/install/) as the Zig IDE.

### Building

```bash
zig build
zig build run
zig build run -- serve foo.bean
```

### Iterating

I'm using [watchexec](https://github.com/watchexec/watchexec) for automatic
rebuilds on file change.

* When iterating on Zig tests in a particular file:

  ```bash
  watchexec -e zig -- zig test src/lexer.zig --test-filter "windows"
  ```

* When iterating on the server (zig code or template):

  ```bash
  watchexec -r -e zig,html -- zig build run -- serve test.bean
  ```

  (page needs to be reloaded manually in the browser)

* When iterating on JS or CSS files, just reload the page while the server is
  running.

### Testing

```bash
zig build test
zig test src/date.zig
```

#### VS Code Extension

Prerequisite: Install [Node](https://nodejs.org/en)

```bash
cd vscode
npm i
npm run test
```

#### Web Viewer

Prerequisite: Install [Bun](https://bun.com/)

```bash
cd tests/puppeteer
bun i
bun test
```
