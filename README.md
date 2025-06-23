# Todos

## Lexer

## Parser

- Validate accounts
- Number expressions

- KeyValue
  - Value = Amount

- Custom

## Renderer

# Editors

## neovim

Put this into your nvim-lspconfig's `config` function:

```lua
    local lspconfig = require 'lspconfig'
    require('lspconfig.configs').zigcount = {
      default_config = {
        cmd = {
          'bash',
          '-c',
          '/Users/moritz/code/zigcount/zig-out/bin/zigcount --lsp 2> >(tee zigcount.log >&2)',
        },
        filetypes = { 'beancount', 'bean' },
        root_dir = require('lspconfig.util').root_pattern 'zigcount.config',
      },
    }
    lspconfig.zigcount.setup {}

```

## VSCode

Use extension in this repo.
