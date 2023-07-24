local lsp = require('lsp-zero')

-- 'recommended' preset without K mapping, replaced by gk below
lsp.preset({
  float_border = 'rounded',
  call_servers = 'local',
  configure_diagnostics = true,
  setup_servers_on_start = true,
  set_lsp_keymaps = {
    preserve_mappings = false,
    omit = {'K', 'gl'},
  },
  manage_nvim_cmp = {
    set_sources = 'recommended',
    set_basic_mappings = true,
    set_extra_mappings = false,
    use_luasnip = true,
    set_format = true,
    documentation_window = true,
  }
})

lsp.ensure_installed({
  'tsserver',
  'eslint',
  'kotlin_language_server',
  'lua_ls',
  'bashls',
  'cssls'
})

local cmp = require('cmp')
local cmp_mappings = lsp.defaults.cmp_mappings({
  ['<CR>'] = cmp.mapping.confirm({ select = true }),
  ['<Tab>'] = cmp.mapping.confirm({ select = true }),
  ['<C-Space>'] = cmp.mapping.complete(),
})

lsp.setup_nvim_cmp({
  mapping = cmp_mappings
})

lsp.on_attach(function(client, bufnr)
	local opts = {buffer = bufnr, remap = false}
	vim.keymap.set('n', 'gk', function() vim.lsp.buf.hover() end, opts)
	vim.keymap.set('n', 'gd', function() vim.lsp.buf.definition() end, opts)
	vim.keymap.set('n', 'gr', function() vim.lsp.buf.references() end, opts)
	vim.keymap.set('n', '<leader>n', function() vim.lsp.buf.rename() end, opts)
	vim.keymap.set('n', '<leader>vws', function() vim.lsp.buf.workspace_symbol() end, opts)
	vim.keymap.set('n', '<leader>vd', function() vim.diagnostic.open_float() end, opts)
	vim.keymap.set('n', '[d', function() vim.diagnostic.goto_next() end, opts)
	vim.keymap.set('n', ']d', function() vim.diagnostic.goto_prev() end, opts)
	vim.keymap.set('n', '<leader>vca', function() vim.lsp.buf.code_action() end, opts)
	vim.keymap.set('i', '<C-h>', function() vim.lsp.buf.signature_help() end, opts)
end)

local lspconfig = require('lspconfig')
lspconfig.eslint.setup({
  on_attach = function(client, bufnr)
    vim.api.nvim_create_autocmd("BufWritePre", {
      buffer = bufnr,
      command = "EslintFixAll",
    })
  end,
})

lsp.setup()
