local builtin = require('telescope.builtin')
vim.keymap.set('n', 'gT', builtin.find_files, {})
vim.keymap.set('n', 'gt', builtin.git_files, {})
vim.keymap.set('n', 'gf', function()
	builtin.grep_string({ search = vim.fn.input("Grep > ") });
end)
