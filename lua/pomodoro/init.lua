local M = {}

local state = {
    tasks = {
        todo = {},
        in_progress = {},
        done = {},
    },
    doc = {
        buf = nil,
        task_lines = {
            todo = 0,
            in_progress = 0,
            done = 0,
        },
        doc_len = {
            todo = 0,
            in_progress = 0,
            done = 0
        }
    },

    keymaps = {},
    buf = nil,
    win = nil,

    timer = nil,
    timer_time = 0,
    cycle = 1,
    cycles = {},
    timer_paused = true,

    last_time = nil
}

local function display_tasks(tasks, prefix)
    if #tasks == 0 then
        return {""}
    end
    local res = {}
    for i, task in ipairs(tasks) do
        res[i] = prefix .. " " .. task
    end
    return res
end

local function render()
    if not state.win or not state.buf then
        return
    end

    local timer_string = string.format(
        "%s%02d:%02d",
        state.timer_paused and "|| " or ">  ",
        math.floor(state.timer_time / 60),
        state.timer_time % 60
    )

    vim.api.nvim_buf_set_option(state.buf, "modifiable", true)

    local lines = {timer_string, "", "# TODO:"}
    vim.list_extend(lines, display_tasks(state.tasks.todo, "-"))
    vim.list_extend(lines, {"", "# IN PROGRESS:"})
    vim.list_extend(lines, display_tasks(state.tasks.in_progress, "- [ ]"))
    vim.list_extend(lines, {"", "# DONE:"})
    vim.list_extend(lines, display_tasks(state.tasks.done, "- [x]"))
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)

    vim.api.nvim_buf_set_option(state.buf, "modifiable", false)
end

local function start_timer()
    local last_time = os.time()

    if state.timer_time <= 0 then
        state.timer_time = state.cycles[state.cycle]
        state.cycle = state.cycle % #state.cycles + 1
    end

    state.timer = vim.uv.new_timer()
    state.timer:start(0, 1000, vim.schedule_wrap(function()
        local now = os.time()
        state.timer_time = state.timer_time - os.difftime(now, last_time)
        last_time = now

        if state.timer_time <= 0 then
            state.timer:close()
            state.timer = nil
            state.timer_paused = true
        end

        render()
    end))
end

local function update_doc()
    if #state.tasks.todo ~= state.doc.doc_len.todo then
        local delta = #state.tasks.todo - state.doc.doc_len.todo
        vim.api.nvim_buf_set_lines(
            state.doc.buf,
            state.doc.task_lines.todo,
            state.doc.task_lines.todo + state.doc.doc_len.todo,
            false,
            state.tasks.todo
        )
        if state.doc.task_lines.in_progress > state.doc.task_lines.todo then
            state.doc.task_lines.in_progress = state.doc.task_lines.in_progress + delta
        end
        if state.doc.task_lines.done > state.doc.task_lines.todo then
            state.doc.task_lines.done = state.doc.task_lines.done + delta
        end
        state.doc.doc_len.todo = #state.tasks.todo
    end

    if #state.tasks.in_progress ~= state.doc.doc_len.in_progress then
        local delta = #state.tasks.in_progress - state.doc.doc_len.in_progress
        vim.api.nvim_buf_set_lines(
            state.doc.buf,
            state.doc.task_lines.in_progress,
            state.doc.task_lines.in_progress + state.doc.doc_len.in_progress,
            false,
            state.tasks.in_progress
        )
        if state.doc.task_lines.done > state.doc.task_lines.in_progress then
            state.doc.task_lines.done = state.doc.task_lines.done + delta
        end
        if state.doc.task_lines.todo > state.doc.task_lines.in_progress then
            state.doc.task_lines.todo = state.doc.task_lines.todo + delta
        end
        state.doc.doc_len.in_progress = #state.tasks.in_progress
    end

    if #state.tasks.done ~= state.doc.doc_len.done then
        local delta = #state.tasks.done - state.doc.doc_len.done
        vim.api.nvim_buf_set_lines(
            state.doc.buf,
            state.doc.task_lines.done,
            state.doc.task_lines.done + state.doc.doc_len.done,
            false,
            state.tasks.done
        )
        if state.doc.task_lines.todo > state.doc.task_lines.done then
            state.doc.task_lines.todo = state.doc.task_lines.todo + delta
        end
        if state.doc.task_lines.in_progress > state.doc.task_lines.done then
            state.doc.task_lines.in_progress = state.doc.task_lines.in_progress + delta
        end
        state.doc.doc_len.done = #state.tasks.done
    end
end

local function timer_toggle()
    state.timer_paused = not state.timer_paused

    if state.timer_paused and state.timer then
        state.timer:close()
        state.timer = nil
        render()
    else
        start_timer()
    end
end

local function make_task_request(task_type)
    task_type = task_type or state.tasks.todo
    local task = vim.fn.input("Task: ")
    if task ~= "" then
        table.insert(task_type, task)
        update_doc()
        render()
    end
end

local function task_done()
    if vim.api.nvim_win_get_cursor(0)[1] == 1 then
        timer_toggle()
        return
    end
    local line = vim.api.nvim_get_current_line()
    if line == "# TODO:" then
        make_task_request(state.tasks.todo)
        return
    elseif line == "# IN PROGRESS:" then
        make_task_request(state.tasks.in_progress)
        return
    elseif line == "# DONE:" then
        make_task_request(state.tasks.done)
        return
    end
    for i, task in ipairs(state.tasks.done) do
        if string.find(line, task) then
            table.remove(state.tasks.done, i)
            break
        end
    end
    for i, task in ipairs(state.tasks.in_progress) do
        if string.find(line, task) then
            table.remove(state.tasks.in_progress, i)
            table.insert(state.tasks.done, task)
            break
        end
    end
    for i, task in ipairs(state.tasks.todo) do
        if string.find(line, task) then
            table.remove(state.tasks.todo, i)
            table.insert(state.tasks.in_progress, task)
            break
        end
    end

    update_doc()
    render()
end

local function parse_buffer(buf)
    state.doc.buf = buf
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local parse_state = 0
    local loop_skip = false
    for i, line in ipairs(lines) do
        loop_skip = false
        if string.find(line, "# TODO") then
            state.doc.task_lines.todo = i
            loop_skip = true
            parse_state = 1
        elseif string.find(line, "# IN PROGRESS") then
            state.doc.task_lines.in_progress = i
            loop_skip = true
            parse_state = 2
        elseif string.find(line, "# DONE") then
            state.doc.task_lines.done = i
            loop_skip = true
            parse_state = 3
        end

        if line == "" then
            if parse_state == 1 then
                state.doc.doc_len.todo = i - state.doc.task_lines.todo - 1
            elseif parse_state == 2 then
                state.doc.doc_len.in_progress = i - state.doc.task_lines.in_progress - 1
            elseif parse_state == 3 then
                state.doc.doc_len.done = i - state.doc.task_lines.done - 1
            end
            loop_skip = true
            parse_state = 0
        end

        if not loop_skip then
            if parse_state == 1 then
                table.insert(state.tasks.todo, line)
            elseif parse_state == 2 then
                table.insert(state.tasks.in_progress, line)
            elseif parse_state == 3 then
                table.insert(state.tasks.done, line)
            end
        end
    end
    if state.doc.task_lines.todo == 0 then
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, {"# TODO:"})
        state.doc.task_lines.todo = #vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
    if state.doc.task_lines.in_progress == 0 then
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, {"# IN PROGRESS:"})
        state.doc.task_lines.in_progress = #vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
    if state.doc.task_lines.done == 0 then
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, {"# DONE:"})
        state.doc.task_lines.done = #vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
end

local function start_pomodoro()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
        vim.api.nvim_win_close(state.win, true)
        state.win = nil
        return
    end
    if state.buf then
        vim.api.nvim_buf_delete(state.buf, {force = true})
        state.buf = nil
        state.tasks = {todo = {}, in_progress = {}, done = {}}
    end
    parse_buffer(vim.api.nvim_get_current_buf())
    local buf = vim.api.nvim_create_buf(false, true)
    state.buf = buf
    vim.api.nvim_set_option_value("modifiable", false, {buf = buf})
    vim.api.nvim_set_option_value("filetype", "markdown", {buf = buf})

    local win = vim.api.nvim_open_win(state.buf, true, {
        split = 'above',
        height = math.floor(vim.api.nvim_win_get_height(0) * 0.75),
    })

    state.win = win

    vim.keymap.set("n", state.keymaps.task_done or "<leader>td", task_done, { buffer = true })
    vim.keymap.set("n", state.keymaps.timer_pause or "<leader>tp", timer_toggle, { buffer = true })
    vim.keymap.set("n", state.keymaps.make_task or "<leader>mt", make_task_request, { buffer = true })

    render()
end

M.setup = function (opts)
    state.keymaps = opts.keymaps or {}
    vim.api.nvim_create_user_command("Pomodoro", start_pomodoro, {})
    state.cycles = opts.cycles or {20 * 60, 10 * 60}
end

return M
