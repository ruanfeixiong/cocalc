##############################################################################
#
#    CoCalc: Collaborative Calculation in the Cloud
#
#    Copyright (C) 2018, Sagemath Inc.
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
###############################################################################

path      = require('path')
path_join = path.join
immutable = require('immutable')
_         = require('underscore')

# CoCalc libraries
{defaults, required} = misc = require('smc-util/misc')
{webapp_client}      = require('../../webapp_client')
{COLORS}             = require('smc-util/theme')
{Avatar}             = require('../../other-users')

# React libraries
{React, rclass, rtypes, ReactDOM} = require('../../smc-react')
{Alert, Button, ButtonToolbar, ButtonGroup, Form, FormControl, FormGroup, ControlLabel, InputGroup, Checkbox, Row, Col, Panel, Breadcrumb} = require('react-bootstrap')

# CoCalc and course components
util = require('../util')
styles = require('../styles')
{DateTimePicker, ErrorDisplay, Icon, LabeledRow, Loading, MarkdownInput, Space, Tip, NumberInput} = require('../../r_misc')
{STEPS, step_direction, step_verb, step_ready} = util
{BigTime} = require('../common')

# Grading specific
{Grading} = require('./models')
{Grade} = require('./grade')
{GradingStats} = require('./stats')
{ROW_STYLE, LIST_STYLE, LIST_ENTRY_STYLE, FLEX_LIST_CONTAINER, EMPTY_LISTING_TEXT, PAGE_SIZE} = require('./const')

# util functions

_current_idx = (student_list, student_id) ->
    current_idx = null
    student_list.map (student, idx) ->
        id = student.get('student_id')
        if student_id == id
            current_idx = idx
    return current_idx

exports._init_state = _init_state = (props) ->
    store      = props.redux.getStore(props.name)
    student_id = props.grading.student_id
    return
        store           : store
        student_id      : student_id
        student_info    : if student_id? then store.student_assignment_info(student_id, props.assignment)
        subdir          : props.grading.subdir
        student_filter  : props.grading.student_filter
        page_number     : props.grading.page_number

exports._update_state = _update_state = (props, next, state) ->
    if misc.is_different(props, next, ['grading', 'assignment'])
        student_id = next.grading.student_id
        return if not student_id?
        subdir     = next.grading.subdir
        grade      = state.store.get_grade(props.assignment, student_id)
        comment    = state.store.get_comments(props.assignment, student_id)
        ret =
            student_id      : student_id
            grade_value     : grade
            grade_comments  : comment
            edited_grade    : grade
            edited_comments : comment
            student_info    : if student_id? then state.store.student_assignment_info(student_id, props.assignment)
            subdir          : subdir
            page_number     : next.grading.page_number
        # reset file listing pager to 0 when switching directories or student
        if props.grading.subdir != subdir or student_id != props.grading.student_id
            ret.page_number = 0
        return ret


exports.GradingStudentAssignment = rclass
    displayName : "CourseEditor-GradingStudentAssignment"

    propTypes :
        name            : rtypes.string.isRequired
        redux           : rtypes.object.isRequired
        assignment      : rtypes.object.isRequired
        students        : rtypes.object.isRequired
        user_map        : rtypes.object.isRequired
        grading         : rtypes.instanceOf(Grading).isRequired

    reduxProps:
        account :
            account_id  : rtypes.string

    getInitialState: ->
        state = _init_state(@props)
        state.active_autogrades = immutable.Set()
        show_all_files = state.store.grading_get_show_all_files()
        state = misc.merge(state, @props.grading.get_listing_files(show_all_files))
        store = @props.redux.getStore(@props.name)
        [student_list, all_points] = store.grading_get_student_list(@props.assignment)
        state.student_list = student_list
        state.all_points   = all_points
        state.current_idx  = _current_idx(student_list, state.student_id)
        return state

    componentWillReceiveProps: (next) ->
        x = _update_state(@props, next, @state)
        @setState(x) if x?

        listing_changed    = @props.grading?.listing != next.grading?.listing
        show_files_changed = @props.grading?.show_all_files != next.grading?.show_all_files
        page_changed       = @props.grading?.page_number != next.grading?.page_number
        if listing_changed or show_files_changed or page_changed
            show_all_files = @state.store.grading_get_show_all_files()
            @setState(next.grading.get_listing_files(show_all_files))

        if @props.grading != next.grading or @props.assignment != next.assignment
            [student_list, all_points] = @state.store.grading_get_student_list(next.assignment)
            @setState(
                student_list : student_list
                all_points   : all_points
                current_idx  : _current_idx(student_list, x.student_id)
            )

    componentDidMount: ->
        show_entry       =  =>
            $(ReactDOM.findDOMNode(@refs.student_list)).find('.active').scrollintoview()
        @scrollToStudent = _.debounce(show_entry, 100)
        @scrollToStudent()

        if @_timer?
            clearInterval(@_timer)
        @_timer = setInterval((=>@actions(@props.name).grading_update_activity()), 60 * 1000)

    componentWillUnmount: ->
        if @_timer?
            clearInterval(@_timer)
        delete @_timer
        # don't call actions.grading_remove_activity, because the user is probably just in another tab

    componentDidUpdate: (prevProps, prevState) ->
        # only scroll when current_idx in the student list changes
        if prevState.current_idx != @state.current_idx
            @scrollToStudent()

    collect_student_path: ->
        return path_join(@props.assignment.get('collect_path'), @state.student_id, @state.subdir)

    open_assignment: (type, filepath) ->
        @actions(@props.name).open_assignment(type, @props.assignment, @state.student_id, filepath)

    jump: (direction, without_grade, collected_files) ->
        @actions(@props.name).grading(
            assignment       : @props.assignment
            student_id       : @state.student_id
            direction        : direction
            without_grade    : without_grade
            collected_files  : collected_files
        )

    previous: (without_grade, collected_files) ->
        @jump(-1, without_grade, collected_files)

    next: (without_grade, collected_files) ->
        @jump(+1, without_grade, collected_files)

    pick_next: (direction=1) ->
        without_grade   = @get_only_not_graded()
        collected_files = @get_only_collected()
        @jump(direction, without_grade, collected_files)

    render_info: ->
        if @props.grading.end_of_list
            <span>End of student list</span>
        else if @state.student_id?
            student_name = @state.store.get_student_name(@state.student_id, true)
            <span style={fontSize:'120%'}>Student <b>{student_name?.full ? 'N/A'}</b></span>

    student_list_entry_click: (student_id) ->
        @actions(@props.name).grading(
            assignment       : @props.assignment
            student_id       : student_id
            direction        : 0
            without_grade    : null
        )

    set_student_filter: (string) ->
        @setState(student_filter:string)
        @actions(@props.name).grading_set_student_filter(string)

    on_key_down_student_filter: (e) ->
        switch e.keyCode
            when 27
                @set_student_filter('')
            when 13
                @pick_next()
                e?.preventDefault?()

    student_list_filter: ->
        disabled = @state.student_filter?.length == 0 ? true

        <form key={'filter_list'} style={{}}>
            <FormGroup>
                <InputGroup>
                    <InputGroup.Addon>
                        Search
                    </InputGroup.Addon>
                    <FormControl
                        autoFocus   = {true}
                        ref         = {'stundent_filter'}
                        type        = {'text'}
                        placeholder = {'any text...'}
                        value       = {@state.student_filter}
                        onChange    = {(e)=>@set_student_filter(e.target.value)}
                        onKeyDown   = {@on_key_down_student_filter}
                    />
                    <InputGroup.Button>
                        <Button
                            bsStyle  = {if disabled then 'default' else 'warning'}
                            onClick  = {=>@set_student_filter('')}
                            disabled = {disabled}
                            style    = {whiteSpace:'nowrap'}
                        >
                            <Icon name='times-circle'/>
                        </Button>
                    </InputGroup.Button>
                </InputGroup>
            </FormGroup>
        </form>


    render_student_list_entries_info: (active, grade_val, points, is_collected) ->
        col = if active then COLORS.GRAY_LL else COLORS.GRAY
        info_style =
            color          : col
            display        : 'inline-block'
            float          : 'right'

        show_grade  = grade_val?.length > 0
        show_points = points? or is_collected
        grade  = if show_grade  then misc.trunc(grade_val, 15) else 'N/G'
        points = if show_points then ", #{points ? 0} pts."    else ''

        if show_points or show_grade
            <span style={info_style}>
                {grade}{points}
            </span>
        else
            null

    render_student_list_presenece: (student_id) ->
        # presence of other teachers
        # cursors are only relevant for the last 10 minutes (componentDidMount updates with a timer)
        min_10_ago = misc.server_minutes_ago(10)
        presence = []
        whoelse = @props.grading.getIn(['cursors', @props.assignment.get('assignment_id'), student_id])
        whoelse?.map (time, account_id) =>
            return if account_id == @props.account_id or time < min_10_ago
            presence.push(
                <Avatar
                    key        = {account_id}
                    size       = {22}
                    account_id = {account_id}
                />
            )
            return

        style =
            marginLeft    : '10px'
            display        : 'inline-block'
            marginTop      : '-5px'
            marginBottom   : '-5px'

        if presence.length > 0
            <div style={style}>
                {presence}
            </div>


    render_student_list_entries: ->
        style        = misc.merge({cursor:'pointer'}, LIST_ENTRY_STYLE)
        avatar_style =
            display        : 'inline-block'
            marginRight    : '10px'
            marginTop      : '-5px'
            marginBottom   : '-5px'

        list = @state.student_list.map (student) =>
            student_id   = student.get('student_id')
            account_id   = student.get('account_id')
            name         = @state.store.get_student_name(student)
            points       = @state.store.get_points_total(@props.assignment, student_id)
            is_collected = @state.store.student_assignment_info(student_id, @props.assignment)?.last_collect?.time?

            # should this student be highlighted in the list?
            current      = @state.student_id == student_id
            active       = if current then 'active' else ''
            grade_val    = @state.store.get_grade(@props.assignment, student_id)

            <li
                key        = {student_id}
                className  = {"list-group-item " + active}
                onClick    = {=>@student_list_entry_click(student_id)}
                style      = {style}
            >
                <span style={float:'left'}>
                    {<div style={avatar_style}>
                        <Avatar
                            size       = {22}
                            account_id = {account_id}
                        />
                    </div> if account_id?}
                    {name}
                    {@render_student_list_presenece(student_id)}
                </span>
                {@render_student_list_entries_info(active, grade_val, points, is_collected)}
            </li>

        if list.length == 0
            list.push(<div style={EMPTY_LISTING_TEXT}>No student matches…</div>)
        return list

    render_student_list: ->
        flex =
            display        : 'flex'
            flexDirection  : 'column'

        [
            <Row key={1}>
                {@student_list_filter()}
            </Row>
            <Row style={FLEX_LIST_CONTAINER} key={2}>
                <ul className='list-group' ref='student_list' style={LIST_STYLE}>
                    {@render_student_list_entries()}
                </ul>
            </Row>
        ]

    get_only_not_graded: ->
        @state.store.grading_get_filter_button('only_not_graded')

    get_only_collected: ->
        @state.store.grading_get_filter_button('only_collected')

    set_only_not_graded: (only_not_graded) ->
        actions = @actions(@props.name)
        actions.grading_set_entry('only_not_graded', only_not_graded)

    set_only_collected: (only_collected) ->
        @setState(student_list_first_selected:false)
        actions = @actions(@props.name)
        actions.grading_set_entry('only_collected', only_collected)

    render_filter_only_not_graded: ->
        only_not_graded = @get_only_not_graded()
        if only_not_graded
            icon = 'check-square-o'
        else
            icon = 'square-o'

        <Button
            onClick  = {=>@set_only_not_graded(not only_not_graded)}
            bsStyle  = {'default'}
        >
            <Icon name={icon} /> Not graded
        </Button>

    render_filter_only_collected: ->
        only_collected = @get_only_collected()
        if only_collected
            icon = 'check-square-o'
        else
            icon = 'square-o'

        <Button
            onClick  = {=>@set_only_collected(not only_collected)}
            bsStyle  = {'default'}
        >
            <Icon name={icon} /> Collected
        </Button>

    render_nav: () ->
        <Col md={3}>
            <Row style={ROW_STYLE}>
                <ButtonGroup>
                    <Button
                        onClick  = {=>@pick_next(-1)}
                        bsStyle  = {'default'}
                        disabled = {@state.current_idx == 0}
                    >
                        <Icon name={'step-backward'} />
                    </Button>
                    <Button
                        onClick  = {=>@pick_next(+1)}
                        bsStyle  = {'primary'}
                    >
                        <Icon name={'step-forward'} /> Pick next
                        <span className='hidden-md'> student</span>
                    </Button>
                </ButtonGroup>
            </Row>
            <Row style={color:COLORS.GRAY}>
                Filter students by:
            </Row>
            <Row style={ROW_STYLE}>
                <ButtonGroup>
                    {@render_filter_only_not_graded()}
                    {@render_filter_only_collected()}
                </ButtonGroup>
            </Row>
        </Col>

    percentile_rank_help: ->
        url = 'https://en.wikipedia.org/wiki/Percentile_rank'
        {open_new_tab} = require('smc-webapp/misc_page')
        open_new_tab(url)

    render_points: ->
        total = @state.store.get_points_total(@props.assignment, @state.student_id)
        pct   = misc.percentRank(@state.all_points, total, true)
        <Row>
            <Col md={10} style={textAlign: 'center'}>
                <ButtonGroup>
                    <Button
                        disabled={true}
                    >
                        Total points
                    </Button>
                    <Button
                        style    = {fontWeight: 'bold', color:'black', paddingLeft:'20px', paddingRight:'20px'}
                        disabled = {true}
                    >
                        {total ? 0}
                    </Button>
                    {<Button
                        style     = {color: COLORS.GRAY}
                        onClick   = {=>@percentile_rank_help()}
                    >
                        {misc.round1(pct)}%
                        <span className='hidden-md'> percentile</span>
                    </Button> if @state.all_points.length >= 5}
                </ButtonGroup>
            </Col>
        </Row>



    render_open_student_file: (filename) ->
        filepath = @filepath(filename)
        <Tip
            title     = {"Open the student's file"}
            title     = {"This opens the corresponding file in the student's project. This allows you to see the progress via 'TimeTravel' for many file types, etc."}
            placement = {'left'}
        >
            <Button
                onClick = {=>@open_assignment('assigned', filepath)}
                bsStyle = {'default'}
                bsSize  = {'small'}
                style   = {color:COLORS.GRAY}
            >
                Student file <Icon name='external-link' />
            </Button>
        </Tip>

    filepath: (filename) ->
        path_join(@state.subdir, filename)

    fullpath: (filename) ->
        path_join(@collect_student_path(), filename)

    # TODO this is pure demo
    autograde: (ext, filename) ->
        # ext in ['ipynb']
        fullpath = @fullpath(filename)
        filepath = @filepath(filename)
        @setState(active_autogrades : @state.active_autogrades.add(filepath))
        done = =>
            @save_points(filename, Math.floor(10 * Math.random()))
            @setState(active_autogrades : @state.active_autogrades.remove(filepath))
        setTimeout(done, 3000)

    render_autograde: (filename) ->
        ext    = misc.separate_file_extension(filename).ext
        active = @state.active_autogrades.includes(@filepath(filename))
        if active
            icon = <Icon name='cc-icon-cocalc-ring' spin />
        else
            icon = <Icon name='graduation-cap' />

        if ext == 'ipynb'
            <Button
                onClick  = {=>@autograde(ext, filename)}
                bsStyle  = {'default'}
                bsSize   = {'small'}
                disabled = {active}
            >
                {icon} Autograde
            </Button>

    listing_header: ->
        header_style =
            background  : COLORS.GRAY_LLL
            color       : COLORS.GRAY
            padding     : '5px 0px'

        <Row style={header_style}>
            <Col md={4}>Filename</Col>
            <Col md={2}>Last modified</Col>
            <Col md={4}>Points</Col>
            {###
            <Col md={2}>Autograde</Col>
            ###}
            <Col md={2} style={textAlign:'right'}>Student file</Col>
        </Row>

    save_points: (filename, points) ->
        filepath = @filepath(filename)
        @actions(@props.name).set_points(@props.assignment, @state.student_id, filepath, points)

    render_points_input: (filename) ->
        filepath = @filepath(filename)
        points   = @state.store.get_points(@props.assignment, @state.student_id, filepath)
        <NumberInput
            number          = {points}
            bsSize          = {'small'}
            min             = {0}
            max             = {99999}
            bsSize          = {'small'}
            formgroupstyle  = {'marginBottom' : 0}
            on_change       = {(val)=>@save_points(filename, val)}
            plusminus       = {true}
            select_on_click = {true}
        />

    render_points_subdir: (subdir) ->
        p = @state.store.get_points_subdir(@props.assignment, @state.student_id, subdir)
        return "Sum: #{p} pts."

    open_subdir: (subdir) ->
        if @state.subdir.length > 0
            name = subdir[@state.subdir.length+1 ..]
        else
            name = subdir
        style =
            fontWeight    : 'bold'
            cursor        : 'pointer'
        <a
            style   = {style}
            onClick = {=>@actions(@props.name).grading(
                assignment       : @props.assignment
                student_id       : @state.student_id
                direction        : 0
                without_grade    : @get_only_not_graded()
                collected_files  : @get_only_collected()
                subdir           : subdir
            )}
        >
            <Icon name='folder-open-o'/> {name}{'/'}
        </a>

    open_file: (filename, masked) ->
        filepath = @filepath(filename)
        style =
            fontWeight    : 'bold'
            cursor        : 'pointer'
        if masked
            style.color      = COLORS.GRAY
            style.fontWeight = 'inherit'
        <a
            style     = {style}
            onClick   = {=>@open_assignment('collected', filepath)}
        >
            {filename}
        </a>

    listing_directory_row: (filename, time) ->
        subdirpath = path_join(@state.subdir, filename)
        [
            <Col key={0} md={4} style={@listing_colstyle2()}>{@open_subdir(subdirpath)}</Col>
            <Col key={1} md={2} style={@listing_colstyle()}>{time}</Col>
            <Col key={2} md={4} style={@listing_colstyle()}>{@render_points_subdir(subdirpath)}</Col>
            <Col key={3} md={2}></Col>
        ]

    listing_file_row: (filename, time, masked) ->
        [
            <Col key={0} md={4} style={@listing_colstyle2()}>{@open_file(filename, masked)}</Col>
            <Col key={1} md={2} style={@listing_colstyle()}>{time}</Col>
            <Col key={2} md={4}>{@render_points_input(filename)}</Col>
            # <Col key={3} md={3}>{@render_autograde(filename)}</Col>
            <Col key={5} md={2} style={textAlign:'right'}>{@render_open_student_file(filename)}</Col>
        ]

    listing_colstyle: ->
        {margin: '10px 0'}

    listing_colstyle2: ->
        misc.merge({overflow: 'hidden', textOverflow: 'ellipsis'}, @listing_colstyle())

    listing_rowstyle: (idx) ->
        col = if idx %% 2 == 0 then 'white' else COLORS.GRAY_LL
        style =
            background     : col
            paddingTop     : '5px'
            paddingBottom  : '5px'
        return misc.merge(style, LIST_ENTRY_STYLE)

    listing_error: (error) ->
        if error = 'no_dir'
            # TODO insert collect button here and refresh listing accordingly ...
            return <div style={EMPTY_LISTING_TEXT}>
                       No directory. Not yet collected from student?
                   </div>
        else
            return <div style={EMPTY_LISTING_TEXT}>
                       <div>Got an error listing directory:</div>
                       <pre>{error}</pre>
                   </div>

    listing_entries: ->
        if not @state.listing?
            return <div style={EMPTY_LISTING_TEXT}><Loading /></div>

        error = @state.listing.get('error')
        return @listing_error(error) if error?

        files = @state.listing.get('files')
        if files?.size > 0
            begin = PAGE_SIZE * (@state.page_number ? 0)
            end   = begin + PAGE_SIZE
            return files.slice(begin, end).map (file, idx) =>
                filename = file.get('name')
                masked   = file.get('mask') ? false
                time     = <BigTime date={(file.get('mtime') ? 0) * 1000} />
                isdir    = file.get('isdir') == true

                <li key={filename} style={@listing_rowstyle(idx)} className={'list-group-item'}>
                    <Row>
                    {
                        if isdir
                            @listing_directory_row(filename, time)
                        else
                            @listing_file_row(filename, time, masked)
                    }
                    </Row>
                </li>
        else
            return <div style={EMPTY_LISTING_TEXT}>No files.</div>

    listing_more_files_info: ->
        num_pages = @state.num_pages ? 1
        page      = (@state.page_number ? 1) + 1
        return null if num_pages == 1 or page >= num_pages
        <Row style={color:COLORS.GRAY} key={'more'}>
            More files are on the <a style={cursor:'pointer'} onClick={=>@listing_page(+1)}>next page</a> …
        </Row>

    listing: ->
        listing = <Row style={FLEX_LIST_CONTAINER} key={0}>
            <ul className='list-group' style={LIST_STYLE}>
                {@listing_entries()}
            </ul>
        </Row>
        more = @listing_more_files_info()
        return (if more? then [listing, more] else listing)

    open_directory: (path) ->
        @setState(subdir : path)
        @actions(@props.name).grading(
            assignment       : @props.assignment
            student_id       : @state.student_id
            direction        : 0
            without_grade    : false
            subdir           : path
        )

    render_listing_path: ->
        crumbs  = [
            <Breadcrumb.Item
                key        = {''}
                onClick    = {=>@open_directory('')}
            >
                <Icon name='home' />
            </Breadcrumb.Item>
        ]

        path = ''
        segments = @state.subdir.split('/')
        segments.map (segment) =>
            path = path_join(path, segment)
            do (path, segment) =>
                crumbs.push(
                    <Breadcrumb.Item
                        key        = {path}
                        onClick    = {=>@open_directory(path)}
                    >
                        {segment}
                    </Breadcrumb.Item>
                )

        <Breadcrumb bsSize='small' style={margin: '0 15px 15px 0'}>
            {crumbs}
        </Breadcrumb>

    listing_page: (offset) ->
        p = @state.page_number + offset
        @actions(@props.name).grading_set_entry('page_number', p)
        @setState(page_number : p)

    render_listing_pager: ->
        if (not @state.num_pages?) or (@state.num_pages ? 1) == 1 or (not @state.page_number?)
            return null
        btn_style =
            whiteSpace: 'nowrap'
        <div style={padding:'0', flex:'0', marginRight: '15px'}>
            <ButtonGroup style={marginBottom:'5px', display:'flex'}>
                <Button
                    onClick    = {=>@listing_page(-1)}
                    disabled   = {@state.page_number <= 0}
                    style      = {btn_style}
                >
                    <Icon name='angle-double-left' /> Prev
                </Button>
                <Button
                    style      = {btn_style}
                    disabled
                >
                    {"#{@state.page_number + 1}/#{@state.num_pages}"}
                </Button>
                <Button
                    onClick    = {=>@listing_page(+1)}
                    disabled   = {@state.page_number >= @state.num_pages - 1}
                    style      = {btn_style}
                >
                     Next <Icon name='angle-double-right' />
                </Button>
            </ButtonGroup>
        </div>

    toggle_show_all_files: ->
        @actions(@props.name).grading_toggle_show_all_files()

    render_toggle_show_all_files: ->
        visible = @state.store.grading_get_show_all_files()
        icon    = if visible then 'eye' else 'eye-slash'
        <div style={padding:'0', flex:'0', marginRight: '15px'}>
            <ButtonGroup style={marginBottom:'5px', display:'flex'}>
                <Tip
                    title     = {'Show/hide files'}
                    tip       = {'By default, less important files are hidden from the files listing.'}
                    placement = {'top'}
                >
                    <Button
                        onClick    = {=>@toggle_show_all_files()}
                        style      = {whiteSpace: 'nowrap'}
                    >
                        <Icon name={icon} />
                    </Button>
                </Tip>
            </ButtonGroup>
        </div>

    collected: ->
        last_collect  = @state.student_info?.last_collect
        if last_collect?.time?
            time      = <BigTime date={last_collect.time} />
        else
            time      = "never"

        # enable button only when we have listing information and some files without errors
        disabled = not @state.listing?
        disabled or= (@state.listing?.get('error')?.length > 0) ? false

        <Row>
            <div style={display: 'flex', flexDirection: 'row'}>
                {@render_toggle_show_all_files()}
                {@render_listing_pager()}
                <div style={padding:'0', flex:'1'}>
                    {@render_listing_path()}
                </div>
                <div style={padding:'0', flex:'0'}>
                    <ButtonGroup style={marginBottom:'5px', display:'flex'}>
                        <Button
                            style    = {whiteSpace:'nowrap'}
                            disabled = {disabled}
                            onClick  = {=>@open_assignment('collected')}
                        >
                            <Tip
                                title     = {'Open the collected files right here in your own project.'}
                                placement = {'bottom'}
                            >
                                <Icon name='folder-open-o' /><span className='hidden-md'> Collected</span> {time}
                            </Tip>
                        </Button>
                        <Button
                            onClick = {=>@open_assignment('assigned')}
                            style   = {whiteSpace:'nowrap'}
                        >
                            <Tip
                                title     = {"Open this directory of files in the student's project."}
                                placement = {'bottom'}
                            >
                                Student <Icon name='external-link' />
                            </Tip>
                        </Button>
                    </ButtonGroup>
                </div>
            </div>
        </Row>

    start_fresh: ->
        @actions(@props.name).grading(
            student_id       : undefined
            assignment       : @props.assignment
            without_grade    : @get_only_not_graded()
            collected_files  : @get_only_collected()
        )

    render_end_of_list: ->
        <Col>
            <Row style={marginTop: '75px', marginBottom:'30px'}>
                <h2 style={textAlign:'center'}>
                    Congratulations! You reached the end of the student list.
                </h2>
                <div style={color:COLORS.GRAY, textAlign:'center'}>
                    Take a deep breath and …
                </div>
            </Row>
            <Row style={textAlign:'center', marginBottom:'100px'}>
                <Button
                    onClick  = {=>@start_fresh()}
                    bsStyle  = {'primary'}
                    bsSize   = {'large'}
                >
                    … take another round <Space/> <Icon name='gavel' />
                </Button>
                <Button
                    style    = {marginLeft: '3rem'}
                    onClick  = {=>@actions(@props.name).grading_stop()}
                    bsStyle  = {'default'}
                    bsSize   = {'large'}
                >
                    <Icon name={'sign-out'} /> Exit
                </Button>
            </Row>
        </Col>

    render: ->
        if not @state.student_id?
            return <div>No student to grade, because there are no collected assignments…</div>

        if @props.grading.end_of_list
            return @render_end_of_list()

        flexcolumn =
            display        : 'flex'
            flexDirection  : 'column'
            marginRight    : '15px'

        <Row
            style={height: '70vh', display: 'flex'}
        >
            <Col md={3} style={misc.merge({marginLeft:'15px'}, flexcolumn)}>
                {@render_student_list()}
            </Col>
            <Col md={9} style={flexcolumn}>
                <Row style={marginBottom: '15px'}>
                    {@render_nav()}
                    <Col md={5}>
                        {@render_points()}
                        <GradingStats all_points={@state.all_points} />
                    </Col>
                    <Grade
                        actions    = {@actions(@props.name)}
                        store      = {@state.store}
                        assignment = {@props.assignment}
                        grading    = {@props.grading}
                        student_id = {@state.student_id}
                    />
                </Row>
                {###
                Info: <code>{misc.to_json(@state.student_info)}</code>.
                <br/>
                ###}
                {@collected()}
                {@listing_header()}
                {@listing()}
            </Col>
        </Row>