-- The palette is shared by Rex clients; only the experimental app renders these panes.
rex.action{
  name = "rex_agent_new_pane",
  title = "New Agent Pane",
  description = "Open a native Claude, Codex, or Pi conversation beside the focused pane in Rex Agent View.",
  category = "Agent",
  keywords = "agent claude codex pi chat conversation pane",
  run = function(ctx, args)
    -- The native shortcut uses a helper CLI. -C does not replace ctx.client_id
    -- for server actions, so it supplies its connected app ID explicitly.
    local client = args.app_client_id or ctx.client_id
    if not client then error("Open Rex Agent View to create an agent pane.", 0) end
    local caller, err = rex.call("client.inspect", { client_id = client })
    if err then error(err, 0) end
    if not caller.client.info or caller.client.info.kind ~= "app" or caller.client.info.name ~= "Rex Agent View" or caller.client.connection_state ~= "connected" then
      error("New Agent Pane is available in Rex Agent View.", 0)
    end
    if not ctx.session_id then error("Select a Rex session before opening an agent pane.", 0) end

    local block = ctx.block_id
    if not block then
      local view
      view, err = rex.session.view{}
      if err then error(err, 0) end
      for _, window in ipairs(view.windows or {}) do
        if window.window_id == view.active_window_id then block = window.focused_block_id; break end
      end
    end
    if not block then error("Select a pane before opening an agent pane.", 0) end

    local function directory(record)
      if type(record) == "table" and type(record.cwd) == "string" and record.cwd ~= "" then return record.cwd end
    end
    local process
    process, err = rex.block.call("com.superlogical.terminal", "process", { block_id = block })
    if err then error(err, 0) end
    local cwd
    if type(process) == "table" then
      cwd = directory(process.foreground) or directory(process.child)
    end
    if not cwd then error("The focused terminal has not reported its working directory yet. Try again shortly.", 0) end
    local result
    result, err = rex.session.new_split{
      anchor_id = block,
      direction = "horizontal",
      side = "after",
      ratio = 0.5,
      focus = true,
      layout = { block = {
        flavor = "com.superlogical.terminal.shell",
        label = "rex-agent:Agent",
        options = { shell = "none", login = false, command = { "/usr/bin/tail", "-f", "/dev/null" }, cwd = cwd },
      } },
    }
    if err then error(err, 0) end
    return result
  end,
}
