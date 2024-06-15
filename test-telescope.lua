local pickers = require "telescope.pickers"
local finders = require "telescope.finders"
local conf = require("telescope.config").values

local actions = require "telescope.actions"
local action_state = require "telescope.actions.state"

local colors = function(opts)
  opts = opts or {}
  pickers.new(opts, {
    prompt_title = "Pick a Process",
    finder = finders.new_table {
      results = { "red", "green", "blue" }
    },
    sorter = conf.generic_sorter(opts),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        print(vim.inspect(selection))
        -- vim.api.nvim_put({ selection[1] }, "", false, true)
      end)
      return true
    end,
  }):find()
end

local native_select = function()
	local items = {'one', 'two'}
	vim.ui.select(items, { label = 'foo> '}, function(choice)
	  coroutine.resume(dap_run_co, choice)
	end)
end

-- native_select()

colors(require("telescope.themes").get_dropdown {})
print("HERE")
