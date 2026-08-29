if vim.g.loaded_harness_neovim then
  return
end
vim.g.loaded_harness_neovim = true

-- Automatically initialize plugin with default options
require("harness_neovim").setup()
