--- @module 'nvim-dap-cs'
--- @brief A Neovim plugin for debugging C# projects with `netcoredbg`.
---
--- This module provides an intelligent set of debug configurations for C# projects,
--- including automatically selecting and attaching to .NET processes and parsing `launchSettings.json`
--- to configure the debugger.
local M = {}

local executable = 'netcoredbg'
if vim.fn.has 'win32' == 1 then
  executable = vim.fn.stdpath 'data' .. '/mason/packages/netcoredbg/netcoredbg/' .. executable .. '.exe'
end

--- @section Plugin Configuration
--- @class default_config Path config to Netcoredbg.
--- @field netcoredbg table The configuration for the `netcoredbg` executable.
--- @field netcoredbg.path string The path to the `netcoredbg` executable. Defaults to 'netcoredbg'.
--- @field allow_multiple boolean Flag to allow multiple project selection.
local default_config = {
  netcoredbg = {
    path = executable,
  },
  -- NOTE: Is this even needed?
  allow_multiple = false,
}

--- @brief A helper function to safely load a Neovim module.
--- @param module_name string The name of the module to load, e.g., 'dap'.
--- @return table module The loaded module.
--- @throws string An error message if the module is not found.
local load_module = function(module_name)
  local ok, module = pcall(require, module_name)
  assert(ok, string.format('dap-cs dependency error: %s not installed', module_name))
  return module
end

--- @brief Extracts the .NET version from a file path ending in `.dll`.
--- @param path string The file path to inspect.
--- @return string|nil The name of the .NET version folder (e.g., 'net8.0') or nil if not found.
local function get_net_version(path)
  local pattern = '(net%d+%.%d)/[^/]+%.dll$'
  local net_folder_name = string.match(path, pattern)

  return net_folder_name
end

--- @brief Prepends a numerical index and the file name to each entry in an array of file paths.
--- If the file path is a .NET DLL, it formats the entry to show the .NET version.
--- @param array string[] A list of file paths.
--- @return string[] result A new list with numerically indexed file names.
local format_for_display = function(array)
  local result = {}
  for i, value in ipairs(array) do
    if type(value) ~= 'table' then
      local dotnet_version = get_net_version(value)
      result[i] = i .. ': ' .. dotnet_version
    else
      result[i] = i .. ': ' .. value.name
    end
  end
  return result
end

--- @brief Presents a numbered list of options to the user for selection.
--- This uses a Neovim input list, which is a blocking prompt.
--- @param prompt_title string The title to display at the top of the list.
--- @param options table The list of options the user can choose from.
--- @return table|nil choice The full selected option string from the `options` table or nil if the user cancels.
local display_selection = function(prompt_title, options)
  local display_list = format_for_display(options)

  table.insert(display_list, 1, prompt_title)
  table.insert(display_list, 2, '')
  table.insert(display_list, #display_list + 1, '')

  local choice = vim.fn.inputlist(display_list)

  if choice > 0 then
    return options[choice]
  else
    return nil
  end
end

--- @class Display_Options
--- @field empty_message string A message to print if no files are found.
--- @field title_message string A title for the selection list if multiple results are found.
--- @field allow_multiple boolean If true, returns all results without prompting for selection.

--- @brief Selects a file or list of files from a set of results.
--- @param results table|nil The file path(s) to be selected from.
--- @param opts Display_Options table of options to customize behavior.
--- @return table|nil result The selected file path, a list of file paths if `allow_multiple` is true, or nil.
local select_file = function(results, opts)
  if type(results) ~= 'table' then
    return results
  end

  if next(results) == nil then
    if opts.empty_message then
      print(opts.empty_message)
    end
    return nil
  end

  if opts.allow_multiple then
    return results
  end

  if #results == 1 then
    return results[1]
  end

  if #results > 1 then
    return display_selection(opts.title_message, results)
  end

  return nil
end

--- @brief Predicate function to identify a .NET project file (`.csproj`).
--- This function is intended for use with file system traversal functions like `vim.fs.find()` or `vim.fs.root()`.
--- @param name string The name of the file to check.
--- @param path string The full path to the file. This parameter is unused in the function's logic.
--- @return boolean True if the file name ends with '.csproj', false otherwise.
local function find_csproj(name, path)
  return name:match '%.csproj$' ~= nil
end

--- @brief Searches for C# project files in a given directory and prompts the user for a selection if needed.
--- @param cwd string|nil The directory to start the search from.
--- @param allow_multiple boolean If true, returns all found project files instead of a single selection.
--- @return table startup_projects The selected project file path(s) or nil.
local find_startup_projects = function(cwd, allow_multiple)
  local project_files = vim.fs.find(find_csproj, { path = cwd, limit = math.huge, type = 'file' })

  local startup_projects = {}

  for _, project_path in ipairs(project_files) do
    local project_root = vim.fn.fnamemodify(project_path, ':h')
    local project_name = vim.fn.fnamemodify(project_path, ':t:r')

    local bin_path = project_root .. '/bin/Debug'
    local startup_config_file = vim.fs.find(string.format('%s.runtimeconfig.json', project_name),
      { path = bin_path, type = 'file' })

    if next(startup_config_file) then
      local dlls = vim.fs.find(string.format('%s.dll', project_name),
        { path = bin_path, limit = math.huge, type = 'file' })

      local project = {
        name = project_name,
        root = project_root,
        dlls = dlls,
      }

      table.insert(startup_projects, project)
    end
  end

  return startup_projects
end
--- @brief Safely reads the content of a JSON file and returns it as a string.
--- Handles potential UTF-8 Byte Order Marks (BOMs) that can cause decoding errors.
--- @param path string The path to the JSON file.
--- @return string|nil The file content as a string, or nil on failure.
local function read_json_file(path)
  local file = io.open(path, 'r')
  if not file then
    return nil
  end
  local content = file:read '*a'
  file:close()

  if not content or content == '' then
    return nil
  end

  -- BOM escape
  if content:sub(1, 3) == '\239\187\191' then
    content = content:sub(4)
  end

  return content
end

--- @brief Prompts the user to select a startup project and returns its directory.
--- @param startup_projects table The directory to start the search from.
--- @return table|nil The path to the selected project directory or nil.
local function choose_startup_project_manually(startup_projects)
  local project_file = select_file(startup_projects, {
    empty_message = 'No start up csproj files found.\nIs the project built?',
    title_message = 'Select .NET Project:',
    allow_multiple = allow_multiple,
  })

  return project_file
end

--- @brief Retrieves the root dir of the project or solution via the active LSP.
--- @return string|nil cwd The path to the project/solution directory or nil.
local function get_root_dir()
  local lsp_clients = vim.lsp.get_clients()
  local cwd = nil

  for _, client in pairs(lsp_clients) do
    if client.name == 'roslyn' or client.name == 'omnisharp' then
      cwd = client.config.root_dir
      break
    end
  end

  if not cwd then
    cwd = vim.fn.getcwd()
  end

  return cwd
end

--- @brief Retrieves environment variables from the launchSettings.json file.
--- @param launch_settings table The decoded JSON file.
--- @return table|nil env_vars Environment variables parsed from the settings json file.
local function get_env_vars(launch_settings)
  local selected_profile = nil
  if launch_settings and launch_settings.profiles then
    for _, profile in pairs(launch_settings.profiles) do
      if profile.commandName == 'Project' then
        selected_profile = profile
        break
      end
    end
  end

  if not selected_profile then
    print "Error: Could not find a 'Project' launch profile."
    return
  end

  local env_vars = selected_profile.environmentVariables or {
    ASPNETCORE_ENVIRONMENT = 'Development',
  }

  if selected_profile.applicationUrl then
    env_vars.ASPNETCORE_URLS = selected_profile.applicationUrl
  end

  return env_vars
end

--- @brief Finds and selects a .NET DLL for a project in the current working directory.
--- This function handles both `launchSettings.json` and console app scenarios.
--- @return string|string[]|nil dll_path The path to the selected DLL or nil.
--- @return string|nil project_path The path to the project directory or nil.
--- @return table|nil env_vars The environment variables from `launchSettings.json` or nil.
local select_dll = function()
  local cwd = get_root_dir()

  local startup_projects = find_startup_projects(cwd, default_config.allow_multiple)
  local projects = {}

  for _, project in pairs(startup_projects) do
    local launch_settings_file = vim.fs.find('launchSettings.json', { path = project.root, type = 'file' })

    if next(launch_settings_file) then
      local settings_file_path = launch_settings_file[1]
      local json_string = read_json_file(settings_file_path)
      if not json_string then
        print 'Error: Could not read launchSettings.json.'
        return
      end

      local launch_settings = vim.json.decode(json_string)
      local env_vars = get_env_vars(launch_settings)

      project.envs = env_vars
      table.insert(projects, project)
    end
  end

  local selected_project = nil
  if #projects == 0 then
    selected_project = choose_startup_project_manually(startup_projects)
  else
    if #projects > 1 then
      selected_project = choose_startup_project_manually(projects)
    else
      selected_project = projects[1]
    end
  end

  if not selected_project then
    return nil
  end

  if next(selected_project.dlls) then
    if #selected_project.dlls > 1 then
      selected_project.dlls = select_file(selected_project.dlls, {
        empty_message = 'No dotnet DLLs found in the "bin" directory. Ensure project has been built.',
        title_message = 'Select .NET Version:',
        allow_multiple = allow_multiple,
      })
    else
      selected_project.dlls = selected_project.dlls[1]
    end
  else
    print 'Could not find DLL.'
    return
  end

  return selected_project
end

--- @brief Sets up the coreclr debug configurations for C# in Neovim's DAP.
--- It defines "Launch Project" and "Attach to Process" configurations.
--- @param dap table The `dap` module.
--- @param dap_utils table The `dap.utils` module.
--- @param config table The plugin configuration table.
--- @field config.dap_configurations table[] A list of additional DAP configurations.
local setup_configuration = function(dap, dap_utils, config)
  dap.configurations.cs = {
    setmetatable({
      type = 'coreclr',
      name = 'Launch Project',
      request = 'launch',
      program = '${file}',
      cwd = '${fileDirname}',
      env = {},
    }, {
      __call = function(curr_config)
        local project = select_dll()
        if not project then
          curr_config.program = dap.ABORT
          return config
        end
        curr_config.cwd = project.root
        curr_config.program = project.dlls
        curr_config.env = project.envs
        return curr_config
      end,
    }),
    {
      type = 'coreclr',
      name = 'Attach to Process',
      request = 'attach',
      processId = dap_utils.pick_process,
    },
  }

  if config == nil or config.dap_configurations == nil then
    return
  end

  for _, dap_config in ipairs(config.dap_configurations) do
    if dap_config.type == 'coreclr' then
      table.insert(dap.configurations.cs, dap_config)
    end
  end
end

--- @brief Sets up the `coreclr` and `netcoredbg` debug adapters for Neovim's DAP.
--- @param dap table The `dap` module.
--- @param config table The plugin configuration table.
local setup_adapter = function(dap, config)
  local adapter = {
    type = 'executable',
    command = config.netcoredbg.path,
    args = { '--interpreter=vscode' },
  }

  dap.adapters.coreclr = adapter
  dap.adapters.netcoredbg = adapter
end

--- @brief The main entry point for setting up the debugger plugin.
--- This function merges user options with defaults, loads dependencies, and sets up the DAP adapter and configurations.
--- @param opts table A table of user options to override the defaults.
function M.setup(opts)
  local config = vim.tbl_deep_extend('force', default_config, opts or {})
  local dap = load_module 'dap'
  local dap_utils = load_module 'dap.utils'
  setup_adapter(dap, config)
  setup_configuration(dap, dap_utils, config)
end

return M
