local M = {}
local utils = require 'minuet.utils'
local job = require 'plenary.job'
local config = require('minuet').config

function M.initial_process_completion_items(items_raw, provider)
    local success
    success, items_raw = pcall(vim.split, items_raw, '<endCompletion>')
    if not success then
        utils.notify('Failed to parse ' .. provider .. "'s content text", 'error', vim.log.levels.INFO)
        return
    end

    local items = {}

    for _, item in ipairs(items_raw) do
        if item:find '%S' then -- only include entries that contains non-whitespace
            -- replace the last \n charecter if it exists
            item = item:gsub('\n$', '')
            -- replace leading \n characters
            item = item:gsub('^\n+', '')
            table.insert(items, item)
        end
    end

    return items
end

function M.complete_openai_base(options, context_before_cursor, context_after_cursor, callback)
    local language = utils.add_language_comment()
    local tab = utils.add_tab_comment()

    local context = language
        .. '\n'
        .. tab
        .. '\n'
        .. '<beginCode>'
        .. context_before_cursor
        .. '<cursorPosition>'
        .. context_after_cursor
        .. '<endCode>'

    local messages = vim.deepcopy(options.few_shots)
    local system = utils.make_system_prompt(options.system, config.n_completions)

    table.insert(messages, 1, { role = 'system', content = system })
    table.insert(messages, { role = 'user', content = context })

    local data = {
        model = options.model,
        -- response_format = { type = 'json_object' }, -- NOTE: in practice this option yiled even worse result
        messages = messages,
    }

    data = vim.tbl_deep_extend('force', data, options.optional or {})

    local data_file = utils.make_tmp_file(data)

    if data_file == nil then
        return
    end

    job:new({
        command = 'curl',
        args = {
            options.end_point,
            '-H',
            'Content-Type: application/json',
            '-H',
            'Authorization: Bearer ' .. vim.env[options.api_key],
            '--max-time',
            tostring(config.request_timeout),
            '-d',
            '@' .. data_file,
        },
        on_exit = vim.schedule_wrap(function(response, exit_code)
            local json = utils.json_decode(response, exit_code, data_file, options.name, callback)

            if not json then
                return
            end

            if not json.choices then
                utils.notify(options.name .. ' API returns no content', 'error', vim.log.levels.INFO)
                callback()
                return
            end

            local items_raw = json.choices[1].message.content

            local items = M.initial_process_completion_items(items_raw, options.name)

            callback(items)
        end),
    }):start()
end

function M.complete_openai_fim_base(options, get_text_fn, context_before_cursor, context_after_cursor, callback)
    local data = {}

    data.model = options.model

    data = vim.tbl_deep_extend('force', data, options.optional or {})

    local language = utils.add_language_comment()
    local tab = utils.add_tab_comment()
    context_before_cursor = language .. '\n' .. tab .. '\n' .. context_before_cursor

    data.prompt = context_before_cursor
    data.suffix = context_after_cursor

    local data_file = utils.make_tmp_file(data)

    if data_file == nil then
        return
    end

    local items = {}
    local request_complete = 0
    local n_completions = config.n_completions
    local has_called_back = false

    local function check_and_callback()
        if request_complete >= n_completions and not has_called_back then
            has_called_back = true
            callback(items)
        end
    end

    for _ = 1, n_completions do
        job:new({
            command = 'curl',
            args = {
                '-L',
                options.end_point,
                '-H',
                'Content-Type: application/json',
                '-H',
                'Accept: application/json',
                '-H',
                'Authorization: Bearer ' .. vim.env[options.api_key],
                '--max-time',
                tostring(config.request_timeout),
                '-d',
                '@' .. data_file,
            },
            on_exit = vim.schedule_wrap(function(response, exit_code)
                -- Increment the request_send counter
                request_complete = request_complete + 1

                local json = utils.json_decode(response, exit_code, data_file, options.name, check_and_callback)

                if not json then
                    return
                end

                if not json.choices then
                    utils.notify(options.name .. ' API returns no content', 'error', vim.log.levels.INFO)
                    check_and_callback()
                    return
                end

                local has_result, result = pcall(get_text_fn, json)

                if has_result then
                    table.insert(items, result)
                end

                check_and_callback()
            end),
        }):start()
    end
end
return M
