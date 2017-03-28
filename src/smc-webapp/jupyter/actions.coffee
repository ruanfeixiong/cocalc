###
Jupyter client

The goal here is to make a simple proof of concept editor for working with
Jupyter notebooks.  The goals are:
 1. to **look** like the normal jupyter notebook
 2. work like the normal jupyter notebook
 3. work perfectly regarding realtime sync and history browsing

###

immutable  = require('immutable')
underscore = require('underscore')

misc       = require('smc-util/misc')

{Actions}  = require('../smc-react')

util       = require('./util')

{cm_options} = require('./cm_options')

jupyter_kernels = undefined

DEFAULT_KERNEL = 'python2'

###
The actions -- what you can do with a jupyter notebook, and also the
underlying synchronized state.
###

class exports.JupyterActions extends Actions

    _init: (project_id, path, syncdb, store, client) =>
        @_state      = 'init'   # 'init', 'load', 'ready', 'closed'
        @store       = store
        store.syncdb = syncdb
        @syncdb      = syncdb
        @_client     = client
        @_is_manager = client.is_project()  # the project client is designated to manage execution/conflict, etc.
        @_account_id = client.client_id()   # project or account's id

        @setState
            error               : undefined
            cur_id              : undefined
            toolbar             : true
            has_unsaved_changes : true
            sel_ids             : immutable.Set()  # immutable set of selected cells
            md_edit_ids         : immutable.Set()  # set of ids of markdown cells in edit mode
            mode                : 'escape'
            cm_options          : cm_options()
            font_size           : @store.get_local_storage('font_size') ? @redux.getStore('account')?.get('font_size') ? 14
            project_id          : project_id
            directory           : misc.path_split(path)?.head
            path                : path

        f = () =>
            @setState(has_unsaved_changes : @syncdb?.has_unsaved_changes())
            setTimeout((=>@setState(has_unsaved_changes : @syncdb?.has_unsaved_changes())), 3000)
        @set_has_unsaved_changes = underscore.debounce(f, 1500)

        @syncdb.on('metadata-change', @set_has_unsaved_changes)
        @syncdb.on('change', @_syncdb_change)

        if not client.is_project() # project doesn't care about cursors
            @syncdb.on('cursor_activity', @_syncdb_cursor_activity)

        if not client.is_project() and window?.$?
            # frontend browser client with jQuery
            @set_jupyter_kernels()  # must be after setting project_id above.

    dbg: (f) =>
        return @_client.dbg("Jupyter('#{@store.get('path')}').#{f}")

    close: =>
        if @_state == 'closed'
            return
        @_state = 'closed'
        @syncdb.close()
        delete @syncdb
        if @_file_watcher?
            @_file_watcher.close()
            delete @_file_watcher

    set_jupyter_kernels: =>
        if jupyter_kernels?
            @setState(kernels: jupyter_kernels)
        else
            f = (cb) =>
                $.ajax(
                    url     : util.get_server_url(@store.get('project_id')) + '/kernels.json'
                    timeout : 3000
                    success : (data) =>
                        try
                            jupyter_kernels = JSON.parse(data)
                            @setState(kernels: jupyter_kernels)
                            cb()
                        catch e
                            @set_error("Error setting Jupyter kernels -- #{data} #{e}")
                ).fail () =>
                    cb(true)
            misc.retry_until_success
                f           : f
                start_delay : 1500
                max_delay   : 15000

    set_error: (err) =>
        if not err?
            @setState(err: undefined)
            return
        cur = @store.get('error')
        if cur
            err = err + '\n\n' + cur
        @setState
            error : err

    set_cell_input: (id, input) =>
        @_set
            type  : 'cell'
            id    : id
            input : input
            start : null
            end   : null

    set_cell_output: (id, output) =>
        @_set
            type   : 'cell'
            id     : id
            output : output

    clear_selected_outputs: =>
        cells = @store.get('cells')
        for id in @store.get_selected_cell_ids_list()
            if cells.get(id).get('output')?
                @_set({type:'cell', id:id, output:null}, false)
        @_sync()

    clear_all_outputs: =>
        @store.get('cells').forEach (cell, id) =>
            if cell.get('output')?
                @_set({type:'cell', id:id, output:null}, false)
            return
        @_sync()

    # prop can be: 'collapsed', 'scrolled'
    toggle_selected_outputs: (prop) =>
        cells = @store.get('cells')
        for id in @store.get_selected_cell_ids_list()
            @_set({type:'cell', id:id, "#{prop}": not cells.get(id).get(prop)}, false)
        @_sync()

    toggle_all_outputs: (prop) =>
        @store.get('cells').forEach (cell, id) =>
            @_set({type:'cell', id:id, "#{prop}": not cell.get(prop)}, false)
            return
        @_sync()

    set_cell_pos: (id, pos, save=true) =>
        @_set({type: 'cell', id: id, pos: pos}, save)

    set_cell_type: (id, cell_type='code') =>
        if cell_type != 'markdown' and cell_type != 'raw' and cell_type != 'code'
            throw Error("cell type (='#{cell_type}') must be 'markdown', 'raw', or 'code'")
        obj =
            type      : 'cell'
            id        : id
            cell_type : cell_type
        if cell_type != 'code'
            # delete output and exec time info when switching to non-code cell_type
            obj.output = obj.start = obj.end = null
        @_set(obj)

    set_selected_cell_type: (cell_type) =>
        sel_ids = @store.get('sel_ids')
        cur_id = @store.get('cur_id')
        if sel_ids.size == 0
            if cur_id?
                @set_cell_type(cur_id, cell_type)
        else
            sel_ids.forEach (id) =>
                @set_cell_type(id, cell_type)
                return

    set_md_cell_editing: (id) =>
        md_edit_ids = @store.get('md_edit_ids')
        if md_edit_ids.contains(id)
            return
        @setState(md_edit_ids : md_edit_ids.add(id))

    set_md_cell_not_editing: (id) =>
        md_edit_ids = @store.get('md_edit_ids')
        if not md_edit_ids.contains(id)
            return
        @setState(md_edit_ids : md_edit_ids.delete(id))

    set_cur_id: (id) =>
        @setState(cur_id : id)
        return

    set_cur_id_from_index: (i) =>
        if not i?
            return
        cell_list = @store.get('cell_list')
        if not cell_list?
            return
        if i < 0
            i = 0
        else if i >= cell_list.size
            i = cell_list.size - 1
        @set_cur_id(cell_list.get(i))

    select_cell: (id) =>
        sel_ids = @store.get('sel_ids')
        if sel_ids.contains(id)
            return
        @setState(sel_ids : sel_ids.add(id))

    unselect_all_cells: =>
        @setState(sel_ids : immutable.Set())

    # select all cells from the currently focused one (where the cursor is -- cur_id)
    # to the cell with the given id, then set the cursor to be at id.
    select_cell_range: (id) =>
        cur_id = @store.get('cur_id')
        if not cur_id?  # must be selected
            return
        sel_ids = @store.get('sel_ids')
        if cur_id == id # nothing to do
            if sel_ids.size > 0
                @setState(sel_ids : immutable.Set())  # empty (cur_id always included)
            return
        i = 0
        v = @store.get('cell_list').toJS()
        for i, x of v
            if x == id
                endpoint0 = i
            if x == cur_id
                endpoint1 = i
        @setState
            sel_ids : immutable.Set( (v[i] for i in [endpoint0..endpoint1]) )
            cur_id  : id

    set_mode: (mode) =>
        @setState(mode: mode)
        if mode == 'escape'
            @set_cursor_locs([])  # none

    set_cell_list: =>
        cells = @store.get('cells')
        if not cells?
            return
        cell_list = util.sorted_cell_list(cells)
        if not cell_list.equals(@store.get('cell_list'))
            @setState(cell_list : cell_list)
        return

    _syncdb_cell_change: (id, new_cell) =>
        if typeof(id) != 'string'
            console.warn("ignoring cell with invalid id='#{JSON.stringify(id)}'")
            return
        cells = @store.get('cells') ? immutable.Map()
        cell_list_needs_recompute = false
        #@dbg("_syncdb_cell_change")("#{id} #{JSON.stringify(new_cell?.toJS())}")
        old_cell = cells.get(id)
        if not new_cell?
            # delete cell
            if old_cell?
                obj = {cells: cells.delete(id)}
                cell_list = @store.get('cell_list')
                if cell_list?
                    obj.cell_list = cell_list.filter((x) -> x != id)
                @setState(obj)
        else
            # change or add cell
            old_cell = cells.get(id)
            if new_cell.equals(old_cell)
                return # nothing to do
            obj = {cells: cells.set(id, new_cell)}
            if not old_cell? or old_cell.get('pos') != new_cell.get('pos')
                cell_list_needs_recompute = true
            @setState(obj)
        if @_is_manager
            @manage_on_cell_change(id, new_cell, old_cell)
        return cell_list_needs_recompute

    _syncdb_change: (changes) =>
        do_init = @_is_manager and @_state == 'init'
        #console.log 'changes', changes, changes?.toJS()
        #@dbg("_syncdb_change")(JSON.stringify(changes?.toJS()))
        @set_has_unsaved_changes()
        cell_list_needs_recompute = false
        changes?.forEach (key) =>
            record = @syncdb.get_one(key)
            switch key.get('type')
                when 'cell'
                    if @_syncdb_cell_change(key.get('id'), record)
                        cell_list_needs_recompute = true
                when 'settings'
                    @setState
                        kernel : record?.get('kernel')
            return
        if cell_list_needs_recompute
            @set_cell_list()
        else if @_is_manager
            @ensure_there_is_a_cell()
        cur_id = @store.get('cur_id')
        if not cur_id? or not @store.getIn(['cells', cur_id])?
            @set_cur_id(@store.get('cell_list')?.get(0))

        if do_init
            @initialize_manager()
        else if @_state == 'init'
            @_state = 'ready'

    _syncdb_cursor_activity: =>
        cells = cells_before = @store.get('cells')
        next_cursors = @syncdb.get_cursors()
        next_cursors.forEach (info, account_id) =>
            if account_id == @_account_id  # don't process information about ourselves
                return
            last_info = @_last_cursors?.get(account_id)
            if last_info?.equals(info)
                # no change for this particular users, so nothing further to do
                return
            # delete old cursor locations
            last_info?.get('locs').forEach (loc) =>
                id = loc.get('id')
                cell = cells.get(id)
                if not cell?
                    return
                cursors = cell.get('cursors') ? immutable.Map()
                if cursors.has(account_id)
                    cells = cells.set(id, cell.set('cursors', cursors.delete(account_id)))
                    return false  # nothing further to do
                return

            # set new cursors
            info.get('locs').forEach (loc) =>
                id = loc.get('id')
                cell = cells.get(id)
                if not cell?
                    return
                cursors = cell.get('cursors') ? immutable.Map()
                loc = loc.set('time', info.get('time')).delete('id')
                locs = (cursors.get(account_id) ? immutable.List()).push(loc)
                cursors = cursors.set(account_id, locs)
                cell = cell.set('cursors', cursors)
                cells = cells.set(id, cell)
                return

        @_last_cursors = next_cursors

        if cells != cells_before
            @setState(cells : cells)

    ensure_there_is_a_cell: =>
        if @_state != 'ready' or not @_is_manager
            return
        cells = @store.get('cells')
        if not cells? or cells.size == 0
            @_set
                type  : 'cell'
                id    : @_new_id()
                pos   : 0
                input : ''

    _set: (obj, save=true) =>
        if @_state == 'closed'
            return
        @syncdb.exit_undo_mode()
        @syncdb.set(obj, save)
        # ensure that we update locally immediately for our own changes.
        @_syncdb_change(immutable.fromJS([misc.copy_with(obj, ['id', 'type'])]))

    _delete: (obj, save=true) =>
        if @_state == 'closed'
            return
        @syncdb.exit_undo_mode()
        @syncdb.delete(obj, save)
        @_syncdb_change(immutable.fromJS([{type:obj.type, id:obj.id}]))

    _sync: =>
        if @_state == 'closed'
            return
        @syncdb.sync()

    save: =>
        # Saves our customer format sync doc-db to disk; the backend will
        # (TODO) also save the normal ipynb file to disk right after.
        @syncdb.save () =>
            @set_has_unsaved_changes()
        @set_has_unsaved_changes()

    save_asap: =>
        @syncdb.save_asap (err) =>
            if err
                setTimeout((()=>@syncdb.save_asap()), 50)

    _new_id: =>
        return misc.uuid().slice(0,8)  # TODO: choose something...; ensure is unique, etc.

    # TODO: for insert i'm using averaging; for move I'm just resetting all to integers.
    # **should** use averaging but if get close re-spread all properly.  OR use strings?
    insert_cell: (delta) =>  # delta = -1 (above) or +1 (below)
        cur_id = @store.get('cur_id')
        if not cur_id? # TODO
            return
        v = @store.get('cell_list')
        if not v?
            return
        adjacent_id = undefined
        v.forEach (id, i) ->
            if id == cur_id
                j = i + delta
                if j >= 0 and j < v.size
                    adjacent_id = v.get(j)
                return false  # break iteration
            return
        cells = @store.get('cells')
        if adjacent_id?
            adjacent_pos = cells.get(adjacent_id)?.get('pos')
        else
            adjacent_pos = undefined
        current_pos = cells.get(cur_id).get('pos')
        if adjacent_pos?
            pos = (adjacent_pos + current_pos)/2
        else
            pos = current_pos + delta
        new_id = @_new_id()
        @_set
            type  : 'cell'
            id    : new_id
            pos   : pos
            input : ''
        @set_cur_id(new_id)
        return new_id  # technically violates CQRS -- but not from the store.

    delete_selected_cells: (sync=true) =>
        selected = @store.get_selected_cell_ids_list()
        if selected.length == 0
            return
        id = @store.get('cur_id')
        @move_cursor_after(selected[selected.length-1])
        if @store.get('cur_id') == id
            @move_cursor_before(selected[0])
        for id in selected
            @_delete({type:'cell', id:id}, false)
        if sync
            @_sync()
        return

    # move all selected cells delta positions, e.g., delta = +1 or delta = -1
    move_selected_cells: (delta) =>
        if delta == 0
            return
        # This action changes the pos attributes of 0 or more cells.
        selected = @store.get_selected_cell_ids()
        if misc.len(selected) == 0
            return # nothing to do
        v = @store.get('cell_list')
        if not v?
            return  # don't even have cell list yet...
        v = v.toJS()  # javascript array of unique cell id's, properly ordered
        w = []
        # put selected cells in their proper new positions
        for i in [0...v.length]
            if selected[v[i]]
                n = i + delta
                if n < 0 or n >= v.length
                    # would move cells out of document, so nothing to do
                    return
                w[n] = v[i]
        # now put non-selected in remaining places
        k = 0
        for i in [0...v.length]
            if not selected[v[i]]
                while w[k]?
                    k += 1
                w[k] = v[i]
        # now w is a complete list of the id's in the proper order; use it to set pos
        t = new Date()
        if underscore.isEqual(v, w)
            # no change
            return
        cells = @store.get('cells')
        changes = immutable.Set()
        for pos in [0...w.length]
            id = w[pos]
            if cells.get(id).get('pos') != pos
                @set_cell_pos(id, pos, false)
        @_sync()

    undo: =>
        @syncdb?.undo()
        return

    redo: =>
        @syncdb?.redo()
        return

    run_cell: (id) =>
        cell = @store.getIn(['cells', id])
        if not cell?
            return
        @_input_editors?[id]?()
        cell_type = cell.get('cell_type') ? 'code'
        switch cell_type
            when 'code'
                @run_code_cell(id)
            when 'markdown'
                @set_md_cell_not_editing(id)
        @save_asap()
        return

    run_code_cell: (id) =>
        @_set
            type         : 'cell'
            id           : id
            state        : 'start'
            start        : null
            end          : null
            output       : null
            exec_count   : null

    run_selected_cells: =>
        v = @store.get_selected_cell_ids_list()
        for id in v
            @run_cell(id)
        @save_asap()

    run_all_cells: =>
        @store.get('cell_list').forEach (id) =>
            @run_cell(id)
            return
        @save_asap()

    move_cursor_after_selected_cells: =>
        v = @store.get_selected_cell_ids_list()
        if v.length > 0
            @move_cursor_after(v[v.length-1])

    move_cursor_to_last_selected_cell: =>
        v = @store.get_selected_cell_ids_list()
        if v.length > 0
            @set_cur_id(v[v.length-1])

    # move cursor delta positions from current position
    move_cursor: (delta) =>
        @set_cur_id_from_index(@store.get_cur_cell_index() + delta)
        return

    move_cursor_after: (id) =>
        i = @store.get_cell_index(id)
        if not i?
            return
        @set_cur_id_from_index(i + 1)
        return

    move_cursor_before: (id) =>
        i = @store.get_cell_index(id)
        if not i?
            return
        @set_cur_id_from_index(i - 1)
        return

    set_cursor_locs: (locs=[]) =>
        if locs.length == 0
            # don't remove on blur -- cursor will fade out just fine
            return
        @_cursor_locs = locs  # remember our own cursors for splitting cell
        @syncdb.set_cursor_locs(locs)

    split_current_cell: =>
        cursor = @_cursor_locs?[0]
        if not cursor?
            return
        if cursor.id != @store.get('cur_id')
            # cursor isn't in currently selected cell, so don't know how to split
            return
        # insert a new cell after the currently selected one
        new_id = @insert_cell(1)
        # split the cell content at the cursor loc
        cell = @store.get('cells').get(cursor.id)
        if not cell?
            return  # this would be a bug?
        cell_type = cell.get('cell_type')
        if cell_type != 'code'
            @set_cell_type(new_id, cell_type)
            @set_md_cell_editing(new_id)
        input = cell.get('input')
        if not input?
            return
        lines  = input.split('\n')
        v      = lines.slice(0, cursor.y)
        line   = lines[cursor.y]
        left = line.slice(0, cursor.x)
        if left
            v.push(left)
        top = v.join('\n')

        v     = lines.slice(cursor.y+1)
        right = line.slice(cursor.x)
        if right
            v = [right].concat(v)
        bottom = v.join('\n')
        @set_cell_input(cursor.id, top)
        @set_cell_input(new_id, bottom)

    # Copy content from the cell below the current cell into the currently
    # selected cell, then delete the cell below the current cell.s
    merge_cell_below: =>
        cur_id = @store.get('cur_id')
        if not cur_id?
            return
        next_id = @store.get_cell_id(1)
        if not next_id?
            return
        cells = @store.get('cells')
        if not cells?
            return
        input  = (cells.get(cur_id)?.get('input') ? '') + '\n' + (cells.get(next_id)?.get('input') ? '')
        @_delete({type:'cell', id:next_id}, false)
        @set_cell_input(cur_id, input)
        return

    merge_cell_above: =>
        @move_cursor(-1)
        @merge_cell_below()
        return

    # Copy all currently selected cells into our internal clipboard
    copy_selected_cells: =>
        cells = @store.get('cells')
        global_clipboard = immutable.List()
        for id in @store.get_selected_cell_ids_list()
            global_clipboard = global_clipboard.push(cells.get(id))
        @store.set_global_clipboard(global_clipboard)
        return

    # Cut currently selected cells, putting them in internal clipboard
    cut_selected_cells: =>
        @copy_selected_cells()
        @delete_selected_cells()

    # Javascript array of num equally spaced positions starting after before_pos and ending
    # before after_pos, so
    #   [before_pos+delta, before_pos+2*delta, ..., after_pos-delta]
    _positions_between: (before_pos, after_pos, num) =>
        if not before_pos?
            if not after_pos?
                pos = 0
                delta = 1
            else
                pos = after_pos - num
                delta = 1
        else
            if not after_pos?
                pos = before_pos + 1
                delta = 1
            else
                delta = (after_pos - before_pos) / (num + 1)
                pos = before_pos + delta
        v = []
        for i in [0...num]
            v.push(pos)
            pos += delta
        return v

    # Paste cells from the internal clipboard; also
    #   delta = 0 -- replace currently selected cells
    #   delta = 1 -- paste cells below last selected cell
    #   delta = -1 -- paste cells above first selected cell
    paste_cells: (delta=1) =>
        cells = @store.get('cells')
        v = @store.get_selected_cell_ids_list()
        if v.length == 0
            return # no selected cells
        if delta == 0 or delta == -1
            cell_before_pasted_id = @store.get_cell_id(-1, v[0])  # one before first selected
        else if delta == 1
            cell_before_pasted_id = v[v.length-1]                 # last selected
        else
            console.warn("paste_cells: invalid delta=#{delta}")
            return
        if delta == 0
            # replace, so delete currently selected
            @delete_selected_cells(false)
        clipboard = @store.get_global_clipboard()
        if not clipboard? or clipboard.size == 0
            return   # nothing more to do
        # put the cells from the clipboard into the document, setting their positions
        if not cell_before_pasted_id?
            # very top cell
            before_pos = undefined
            after_pos  = cells.getIn([v[0], 'pos'])
        else
            before_pos = cells.getIn([cell_before_pasted_id, 'pos'])
            after_pos  = cells.getIn([@store.get_cell_id(+1, cell_before_pasted_id), 'pos'])
        positions = @_positions_between(before_pos, after_pos, clipboard.size)
        clipboard.forEach (cell, i) =>
            cell = cell.set('id', @_new_id())   # randomize the id of the cell
            cell = cell.set('pos', positions[i])
            @_set(cell, false)
            return
        @_sync()

    toggle_toolbar: =>
        @setState(toolbar: not @store.get('toolbar'))

    toggle_header: =>
        @redux?.getActions('page').toggle_fullscreen()

    # zoom in or out delta font sizes
    set_font_size: (pixels) =>
        @setState
            font_size : pixels
        # store in localStorage
        @set_local_storage('font_size', pixels)

    set_local_storage: (key, value) =>
        if localStorage?
            current = localStorage[@name]
            if current?
                current = misc.from_json(current)
            else
                current = {}
            if value == null
                delete current[key]
            else
                current[key] = value
            localStorage[@name] = misc.to_json(current)

    zoom: (delta) =>
        @set_font_size(@store.get('font_size') + delta)

    set_scroll_state: (state) =>
        @set_local_storage('scroll', state)

    # File --> Open: just show the file listing page.
    file_open: =>
        @redux?.getProjectActions(@store.get('project_id')).set_active_tab('files')
        return

    register_input_editor: (id, save_value) =>
        @_input_editors ?= {}
        @_input_editors[id] = save_value

    unregister_input_editor: (id) =>
        delete @_input_editors?[id]

    set_kernel: (kernel) =>
        if @store.get('kernel') != kernel
            if @_jupyter_kernel?
                @_jupyter_kernel?.close()
                delete @_jupyter_kernel
            @_set
                type   : 'settings'
                kernel : kernel
            @setState(cm_options : cm_options(kernel))

    show_history_viewer: () =>
        @redux.getProjectActions(@store.get('project_id'))?.open_file
            path       : misc.history_path(@store.get('path'))
            foreground : true

    ###
    MANAGE:

    Code that manages execution and conflict resolution/sanity.
    This must run in exactly ONE client.   For now, that client
    will be the project itself.
    ###

    # Called exactly once when the manager first starts up after the store is initialized.
    # Here we ensure everything is in a consistent state so that we can react
    # to changes later.
    initialize_manager: =>
        dbg = @dbg("initialize_manager")
        dbg("cells at manage_init = #{JSON.stringify(@store.get('cells')?.toJS())}")
        @init_file_watcher()
        @_load_from_disk_if_newer () =>
            @_state = 'ready'
            @ensure_there_is_a_cell()
            if not @store.get('kernel')?
                @set_kernel(DEFAULT_KERNEL)

    # _manage_cell_change is called after a cell change has been
    # incorporated into the store by _syncdb_cell_change.
    # It should do things like ensure any cell with a compute request
    # gets computed, that all positions are unique, that there is a
    # cell, etc.  Only one client will run this code.
    manage_on_cell_change: (id, new_cell, old_cell) =>
        dbg = @dbg("manage_on_cell_change(id='#{id}')")
        dbg("new_cell='#{misc.to_json(new_cell?.toJS())}',old_cell='#{misc.to_json(old_cell?.toJS())}')")

        if not new_cell?
            # TODO: delete cell -- if it was running, stop it.
            return

        if new_cell.get('state') == 'start' and old_cell?.get('state') != 'start'
            @manager_run_cell(id)
            return

    # Runs only on the backend
    manager_run_cell: (id) =>
        dbg = @dbg("manager_run_cell(id='#{id}')")
        dbg()

        cell   = @store.get('cells').get(id)
        input  = (cell.get('input') ? '').trim()
        kernel = @store.get('kernel') ? 'python2'  # TODO...

        @_jupyter_kernel ?= @_client.jupyter_kernel(name: kernel)
        if @_jupyter_kernel.name != kernel
            # user has since changed the kernel, so close this one and make a new one
            @_jupyter_kernel.close()
            @_jupyter_kernel = @_client.jupyter_kernel(name: kernel)

        jupyter_kernel = @_jupyter_kernel

        # For efficiency reasons (involving syncdb patch sizes),
        # outputs is a map from the (string representations of) the numbers
        # from 0 to n-1, where there are n messages.
        outputs    = {}
        exec_count = null
        state      = 'run'
        n          = 0
        start      = null
        end        = null
        set_cell = =>
            dbg("set_cell: state='#{state}', outputs='#{misc.to_json(outputs)}', exec_count=#{exec_count}")
            @_set
                type       : 'cell'
                id         : id
                state      : state
                kernel     : kernel
                output     : outputs
                exec_count : exec_count
                start      : start
                end        : end
        report_started = =>
            if n > 0
                # do nothing -- already getting output
                return
            set_cell()
        setTimeout(report_started, 250)

        jupyter_kernel.execute_code
            code : input
            cb   : (err, mesg) =>
                dbg("got mesg='#{JSON.stringify(mesg)}'")
                if err
                    mesg = {error:err}
                    state = 'done'
                    end   = new Date() - 0
                    set_cell()
                else if mesg.content.execution_state == 'idle'
                    state = 'done'
                    end   = new Date() - 0
                    set_cell()
                else if mesg.content.execution_state == 'busy'
                    start = new Date() - 0
                    state = 'busy'
                    # If there was no output during the first few ms, we set the start to running
                    # and start reporting output.  We don't just do this immediately, since that's
                    # a waste of time, as very often the whole computation takes little time.
                    setTimeout(report_started, 250)
                if not err
                    if mesg.content.execution_count?
                        exec_count = mesg.content.execution_count
                    mesg.content = misc.copy_without(mesg.content, ['execution_state', 'code', 'execution_count'])
                    for k, v of mesg.content
                        if misc.is_object(v) and misc.len(v) == 0
                            delete mesg.content[k]
                    if misc.len(mesg.metadata) > 0
                        mesg.content.metadata = mesg.metadata
                    if misc.len(mesg.buffers) > 0
                        mesg.content.buffers = mesg.buffers
                    if misc.len(mesg.content) == 0
                        # nothing to send.
                        return
                    jupyter_kernel.process_output(mesg.content)
                outputs[n] = mesg.content
                n += 1
                set_cell()

    init_file_watcher: =>
        dbg = @dbg("file_watcher")
        dbg()
        @_file_watcher = @_client.watch_file
            path     : @store.get('path')
            interval : 3000

        @_file_watcher.on 'change', =>
            dbg("change")
            # TODO: have to guard against saving file to disk.
            @load_ipynb_file()

        @_file_watcher.on 'delete', =>
            dbg('delete')

    _load_from_disk_if_newer: (cb) =>
        dbg = @dbg("load_from_disk_if_newer")
        last_changed = @syncdb.last_changed()
        dbg("syncdb last_changed=#{last_changed}")
        @_client.path_stat
            path : @store.get('path')
            cb   : (err, stats) =>
                dbg("stats.ctime = #{stats?.ctime}")
                if err
                    dbg("err stat'ing file: #{err}")
                    # TODO
                else if not last_changed? or stats.ctime > last_changed
                    dbg("disk file changed more recently than edits, so loading")
                    @load_ipynb_file()
                else
                    dbg("stick with database version")
                cb?(err)

    load_ipynb_file: =>
        dbg = @dbg("load_ipynb_file")
        dbg("reading file")
        @_client.path_read
            path       : @store.get('path')
            maxsize_MB : 10   # TODO: increase -- will eventually be able to handle a pretty big file!
            cb         : (err, content) =>
                if err
                    # TODO: need way to report this to frontend
                    dbg("error reading file: #{err}")
                    return
                try
                    content = JSON.parse(content)
                catch err
                    dbg("error parsing ipynb file: #{err}")
                    return
                @set_to_ipynb(content)

    # Given an ipynb JSON object, set the syncdb (and hence the store, etc.) to
    # the notebook defined by that object.
    set_to_ipynb: (ipynb) =>
        @_state = 'load'
        if not ipynb?
            @syncdb.delete()
            @_state = 'ready'
            @ensure_there_is_a_cell()  # just in case the ipynb file had no cells (?)
            return

        @syncdb.exit_undo_mode()

        # We re-use any existing ids to make the patch that defines changing
        # to the contents of ipynb more efficient.   In case of a very slight change
        # on disk, this can be massively more efficient.
        existing_ids = @store.get('cell_list')?.toJS() ? []

        # delete everything
        @syncdb.delete(undefined, false)

        # Set the kernel and other settings
        kernel = ipynb.metadata?.kernelspec?.name ? 'python2'  # TODO - need defaults
        if kernel != @store.get('kernel')
            @_jupyter_kernel?.close()
            delete @_jupyter_kernel
        @_jupyter_kernel ?= @_client.jupyter_kernel(name: kernel)

        set = (obj) =>
            @syncdb.set(obj, false)

        if ipynb.nbformat <= 3
            # Handle older format.
            ipynb.cells ?= []
            for worksheet in ipynb.worksheets
                for cell in worksheet.cells
                    if cell.input?
                        cell.source = cell.input
                        delete cell.input
                    ipynb.cells.push(cell)

        # Read in the cells
        if ipynb.cells?
            n = 0
            for cell in ipynb.cells
                if cell.source?
                    # "If you intend to work with notebook files directly, you must allow multi-line
                    # string fields to be either a string or list of strings."
                    # https://nbformat.readthedocs.io/en/latest/format_description.html#top-level-structure
                    if misc.is_array(cell.source)
                        input = cell.source.join('')
                    else
                        input = cell.source
                if cell.execution_count?
                    exec_count = cell.execution_count
                else if cell.prompt_number?
                    exec_count = cell.prompt_number
                else
                    exec_count = null

                cell_type = cell.cell_type ? 'code'

                types = ['image/svg+xml', 'image/png', 'image/jpeg', 'text/html', 'text/markdown', 'text/plain', 'text/latex']
                if cell.outputs?.length > 0
                    output = {}
                    for k, content of cell.outputs

                        if ipynb.nbformat <= 3
                            # fix old deprecated fields
                            if content.output_type == 'stream'
                                if misc.is_array(content.text)
                                    content.text = content.text.join('')
                                content = {name:content.stream, text:content.text}
                            else
                                for i, t of types
                                    [a,b] = t.split('/')
                                    if content[b]?
                                        content = {data:{"#{t}": content[b]}}
                                        break  # at most one data per message.
                                if content.text?
                                    content = {data:{'text/plain':content.text}}

                        if content.data?
                            for key, val of content.data
                                if misc.is_array(val)
                                    content.data[key] = val.join('')

                        delete content.prompt_number  # in some files
                        @_jupyter_kernel.process_output(content)
                        output[k] = content
                else
                    output = null

                set
                    type       : 'cell'
                    id         : existing_ids[n] ? @_new_id()
                    pos        : n
                    input      : input
                    output     : output
                    cell_type  : cell_type
                    exec_count : exec_count

                n += 1

        @syncdb.sync () =>
            @set_kernel(kernel)
            # Wait for the store to get fully updated in response to the sync.
            @_state = 'ready'
            if not ipynb.cells? or ipynb.cells.length == 0
                @ensure_there_is_a_cell()  # the ipynb file had no cells (?)

