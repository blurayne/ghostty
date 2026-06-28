-- ghostty_lsp.lua
-- Neovim LSP configuration for ghostty-config-lsp.
--
-- Usage (add to your init.lua or a plugin's config):
--
--   require("ghostty_lsp").setup()
--
-- Prerequisites:
--   - ghostty-config-lsp binary on PATH (build with: zig build emit-lsp)
--   - nvim-lspconfig installed (https://github.com/neovim/nvim-lspconfig)

local M = {}

--- Default options.
local defaults = {
  --- Path to the ghostty-config-lsp binary.
  --- If nil, the binary is searched on PATH.
  server_path = "ghostty-config-lsp",
  --- Extra arguments passed to the server (useful for debug flags).
  server_args = {},
  --- Additional lspconfig options merged into the server config.
  lspconfig_opts = {},
}

--- Filetype detection for ghostty config files.
--- Ghostty configs live at:
---   ~/.config/ghostty/config   (XDG default)
---   $GHOSTTY_CONFIG_DIR/config
---
--- We detect by path pattern rather than extension.
local function setup_filetype_detection()
  vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    pattern = { "*/ghostty/config", "*/.config/ghostty/config" },
    callback = function()
      vim.bo.filetype = "ghostty"
    end,
    desc = "Detect Ghostty config files",
  })
end

--- Register `ghostty` as a language with basic syntax highlighting rules.
local function setup_syntax()
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "ghostty",
    callback = function()
      vim.cmd([[
        syntax clear
        syntax match ghosttyComment  "#.*$"
        syntax match ghosttyKey      "^\s*[a-zA-Z][a-zA-Z0-9-]*\ze\s*="
        syntax match ghosttyEquals   "="
        syntax match ghosttyValue    "=\s*\zs.*$"
        highlight default link ghosttyComment  Comment
        highlight default link ghosttyKey      Keyword
        highlight default link ghosttyEquals   Operator
        highlight default link ghosttyValue    String
      ]])
    end,
    desc = "Ghostty config syntax highlighting",
  })
end

--- Start the LSP client.
--- @param opts table Options (see `defaults` above).
function M.setup(opts)
  opts = vim.tbl_deep_extend("force", defaults, opts or {})

  setup_filetype_detection()
  setup_syntax()

  -- Try to load nvim-lspconfig; if not installed, set up a minimal client.
  local ok, lspconfig = pcall(require, "lspconfig")
  if ok then
    -- Register with lspconfig's server registry (requires nvim-lspconfig >= 0.1.7).
    local configs = require("lspconfig.configs")
    if not configs.ghostty_config_ls then
      configs.ghostty_config_ls = {
        default_config = {
          cmd = vim.list_extend({ opts.server_path }, opts.server_args),
          filetypes = { "ghostty" },
          root_dir = lspconfig.util.root_pattern(".git", "config"),
          single_file_support = true,
          settings = {},
        },
        docs = {
          description = [[
Ghostty config language server.
Provides completion, hover documentation, and diagnostics for
~/.config/ghostty/config files.

Build from source:
  zig build emit-lsp

See https://github.com/ghostty-org/ghostty for more information.
          ]],
        },
      }
    end

    lspconfig.ghostty_config_ls.setup(
      vim.tbl_deep_extend("force", {}, opts.lspconfig_opts)
    )
  else
    -- Minimal LSP client without nvim-lspconfig.
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "ghostty",
      callback = function(args)
        vim.lsp.start({
          name = "ghostty-config-lsp",
          cmd = vim.list_extend({ opts.server_path }, opts.server_args),
          root_dir = vim.fs.root(args.buf, { ".git", "config" }),
          single_file_support = true,
        })
      end,
      desc = "Start ghostty-config-lsp",
    })
  end
end

return M
