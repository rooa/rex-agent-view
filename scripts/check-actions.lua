local source = rex.args.source
local action
local state = { views = 0 }
local context = { client_id = "client:experiment", session_id = "session:other-project", block_id = "block:focused" }
rex = {
  action = function(value) action = value end,
  bind = function() error("The integration must not install a global key binding") end,
  call = function(method, args)
    assert(method == "client.inspect" and args.client_id == (state.app_client or context.client_id))
    return { client = { info = { kind = "app", name = state.client_name }, connection_state = state.connection_state or "connected" } }
  end,
  block = { call = function(creator, method, args)
    assert(creator == "com.superlogical.terminal" and method == "process")
    assert(args.block_id == (state.explicit_block or "block:focused"))
    return state.process
  end },
  session = {
    view = function()
      state.views = state.views + 1
      if state.view_error then return nil, state.view_error end
      return { active_window_id = "window:active", windows = {
        { window_id = "window:other", focused_block_id = "block:wrong" },
        { window_id = "window:active", focused_block_id = "block:fallback" },
      } }
    end,
    new_split = function(args)
      if state.split_error then return nil, state.split_error end
      state.created = args
      return { block_ids = { "block:new" } }
    end,
  },
}
dofile(source)
assert(action.name == "rex_agent_new_pane" and action.title == "New Agent Pane" and action.category == "Agent")
assert(action.keywords:find("claude") and action.keywords:find("codex"))
state.client_name = "Rex Beta"
assert(not pcall(action.run, context, {}) and state.created == nil)
state.client_name = "Rex Agent View"
state.process = { foreground = { cwd = "/Projects/current project" }, child = { cwd = "/Projects/old" } }
local result = action.run(context, {})
assert(result.block_ids[1] == "block:new")
assert(state.created.anchor_id == "block:focused" and state.created.direction == "horizontal" and state.created.side == "after")
assert(state.created.ratio == 0.5 and state.created.focus == true and state.views == 0)
assert(state.created.layout.block.flavor == "com.superlogical.terminal.shell" and state.created.layout.block.label == "rex-agent:Agent")
local options = state.created.layout.block.options
assert(options.cwd == "/Projects/current project" and options.shell == "none" and options.login == false)
assert(#options.command == 3 and options.command[1] == "/usr/bin/tail" and options.command[2] == "-f" and options.command[3] == "/dev/null")
-- Rex keeps the helper CLI as ctx.client_id even when -C targets the app.
context.client_id = "client:helper-cli"
state.app_client = "client:experiment"
action.run(context, { app_client_id = state.app_client })
state.connection_state = "disconnected"
state.created = nil
assert(not pcall(action.run, context, { app_client_id = state.app_client }) and state.created == nil)
state.connection_state = nil
state.app_client = nil
context.client_id = "client:experiment"
state.process = { child = { cwd = "/Projects/child" } }
context.block_id = nil
state.explicit_block = "block:fallback"
action.run(context, {})
assert(state.created.anchor_id == "block:fallback" and state.created.layout.block.options.cwd == "/Projects/child" and state.views == 1)
state.process = { foreground = 123, child = 456, home = "/Users/fallback" }
state.created = nil
assert(not pcall(action.run, context, {}) and state.created == nil)
state.process = { foreground = { cwd = "/Projects/current project" } }
state.view_error = "view unavailable"
local ok, err = pcall(action.run, context, {})
assert(not ok and tostring(err):find("view unavailable") and state.created == nil)
state.view_error = nil
context.block_id = "block:focused"
state.explicit_block = nil
state.split_error = "split unavailable"
ok, err = pcall(action.run, context, {})
assert(not ok and tostring(err):find("split unavailable") and state.created == nil)
context.session_id = nil
assert(not pcall(action.run, context, {}) and state.created == nil)
return { passed = true }
