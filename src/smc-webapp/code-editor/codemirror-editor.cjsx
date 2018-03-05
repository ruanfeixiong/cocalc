###
Single codemirror-based file editor

This is a wrapper around a single codemirror editor view.
###

SAVE_INTERVAL_MS = 750

{React, ReactDOM,
 rclass, rtypes}     = require('../smc-react')
{three_way_merge}    = require('smc-util/syncstring')
{debounce, throttle} = require('underscore')
misc                 = require('smc-util/misc')

{Cursors}            = require('../jupyter/cursors')

{cm_options}         = require('./cm-options')
doc                  = require('./doc')


STYLE =
    width        : '100%'
    overflow     : 'auto'
    marginbottom : '1ex'
    minheight    : '2em'
    border       : '1px solid #ccc'
    borderRadius : '3px'
    background   : '#fff'

exports.CodemirrorEditor = rclass
    displayName: 'CodeEditor-CodemirrorEditor'

    propTypes :
        id        : rtypes.string.isRequired
        actions   : rtypes.object.isRequired
        path      : rtypes.string.isRequired
        font_size : rtypes.number.isRequired
        cursors   : rtypes.immutable.Map
        scroll    : rtypes.immutable.Map
        read_only : rtypes.bool
        is_current: rtypes.bool

    reduxProps :
        account :
            editor_settings : rtypes.immutable.Map.isRequired

    getInitialState: ->
        has_cm : false

    shouldComponentUpdate: (props, state) ->
        return misc.is_different(@state, state, ['has_cm']) or \
               misc.is_different(@props, props, ['editor_settings', 'font_size', 'cursors', 'read_only'])

    componentDidMount: ->
        @init_codemirror()

    componentWillReceiveProps: (next) ->
        if @props.font_size != next.font_size
            @cm_update_font_size()
        if @props.read_only != next.read_only
            @cm?.setOption('readOnly', next.read_only)

    cm_refresh: ->
        @cm?.refresh()
        setTimeout((=>@cm?.refresh()), 0)

    cm_update_font_size: ->
        if not @cm?
            return
        # 1. It's important to move the scroll position upon zooming -- otherwise the cursor line
        # move UP/DOWN after zoom, which is very annoying.
        # 2. We have to do the scrollTo in the next render loop, since otherwise
        # the getScrollInfo function below will return the sizing data about
        # the cm instance before the above css font-size change has been rendered.
        scroll_before = @cm.getScrollInfo()
        elt = $(@cm.getWrapperElement()).find('.CodeMirror-scroll')
        elt.css('opacity', 0)  # reduce some ugly jumpiness
        f = =>
            if not @cm?
                return
            elt.css('opacity', 1)
            @cm.refresh()
            scroll_after = @cm.getScrollInfo()
            x = (scroll_before.left / scroll_before.width) * scroll_after.width
            y = (((scroll_before.top+scroll_before.clientHeight/2) / scroll_before.height) * scroll_after.height) - scroll_after.clientHeight/2
            @cm.scrollTo(x, y)
        setTimeout(f, 0)

    componentWillUnmount: ->
        if @cm?
            @save_scroll_position()
            @_cm_destroy()

    _cm_undo: ->
        @props.actions.undo()

    _cm_redo: ->
        @props.actions.redo()

    _cm_destroy: ->
        if not @cm?
            return
        @props.actions.unset_cm(@props.id)
        delete @_cm_last_remote
        delete @cm.undo
        delete @cm.redo
        $(@cm.getWrapperElement()).remove()  # remove from DOM -- "Remove this from your tree to delete an editor instance."
        delete @cm

    _cm_cursor: ->
        if not @cm?
            return
        locs = ({x:c.anchor.ch, y:c.anchor.line} for c in @cm.listSelections())
        # is cursor move is being caused by external setValueNoJump, so just a side effect of something another user did.
        side_effect = @cm._setValueNoJump
        @props.actions.set_cursor_locs(locs, side_effect)

    save_scroll_position: ->
        if not @cm?
            return
        info = misc.copy_with(@cm.getScrollInfo(), ['left', 'top', 'clientHeight', 'height', 'width'])
        info.sel = @cm.listSelections()
        @props.actions.save_scroll_position(@props.id, info)

    save_state: ->
        if not @cm?
            return
        @props.actions.set_syncstring_to_codemirror()
        @props.actions.syncstring_save()

    init_codemirror: ->
        node = $(ReactDOM.findDOMNode(@)).find("textarea")[0]
        if not node?
            return

        options = cm_options
            filename        : @props.path
            editor_settings : @props.editor_settings
            actions         : @props.actions
            frame_id        : @props.id

        @_style_active_line = options.styleActiveLine
        options.styleActiveLine = false

        @cm = CodeMirror.fromTextArea(node, options)

        d   = doc.get(path: @props.path, cm: @cm)
        if d?
            @cm.swapDoc(d)

        e = $(@cm.getWrapperElement())
        e.addClass('smc-vfill')
        # The Codemirror themes impose their own weird fonts, but most users want whatever
        # they've configured as "monospace" in their browser.  So we force that back:
        e.attr('style', e.attr('style') + '; height:100%; font-family:monospace !important;')
        # see http://stackoverflow.com/questions/2655925/apply-important-css-style-using-jquery

        @save_state_throttle = throttle(@save_state, SAVE_INTERVAL_MS, {leading:false})

        @cm.on 'change', (instance, changeObj) =>
            if changeObj.origin? and changeObj.origin != 'setValue'
                @save_state_throttle()
                @props.actions.exit_undo_mode()

        @cm.on 'focus', =>
            #@props.actions.set_active_id(@props.id)
            if @_style_active_line
                @cm?.setOption('styleActiveLine', true)

        @cm.on 'blur', =>
            if @_style_active_line
                @cm?.setOption('styleActiveLine', false)

        save_scroll = debounce(@save_scroll_position, 500)

        @cm.on 'scroll', save_scroll

        @cm.on 'cursorActivity', @_cm_cursor
        @cm.on 'cursorActivity', save_scroll

        # replace undo/redo by our sync aware versions
        @cm.undo = @_cm_undo
        @cm.redo = @_cm_redo

        if @props.is_current
            @cm?.focus()

        setTimeout((=>@cm_refresh(); if @props.is_current then @cm?.focus()), 0)

        @props.actions.set_cm(@props.id, @cm)

        if @props.scroll?
            sel = @props.scroll.get('sel')?.toJS()
            if sel?
                @cm.setSelections(sel)
            scroll_before = @props.scroll.toJS()
            scroll_after  = @cm.getScrollInfo()
            x = (scroll_before.left / scroll_before.width) * scroll_after.width
            y = (((scroll_before.top+scroll_before.clientHeight/2) / scroll_before.height) * scroll_after.height) - scroll_after.clientHeight/2
            @cm.scrollTo(x, y)

        @cm.setOption('readOnly', @props.read_only)
        @setState(has_cm: true)

    render_cursors: ->
        if @props.cursors? and @cm? and @state.has_cm
            # Very important not to render without cm defined, because that renders to static Codemirror instead.
            <Cursors
                cursors    = {@props.cursors}
                codemirror = {@cm} />

    render: ->
        style = misc.copy(STYLE)
        style.fontSize = "#{@props.font_size}px"
        <div
            style     = {style}
            className = 'smc-vfill' >
            {@render_cursors()}
            <textarea />
        </div>