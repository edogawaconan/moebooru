import Mousetrap from 'mousetrap'

$ = jQuery

export default class Menu
  constructor: ->
    $ @initialize


  initialize: =>
    @menu = $('#main-menu')

    if @menu.length > 0
      @setHighlight()
      @setPostModerateCount()
      @syncForumMenu()
      @showHelpItem()

    $(document).on 'click', '#login-link', (e) ->
      e.preventDefault()
      User.run_login false, ->
        Cookie.put 'notice', 'You have been logged in.'
        document.location.reload()


    $(document).on 'click', '#forum-mark-all-read', (e) ->
      e.preventDefault()
      Forum.mark_all_read()

    $(document).on 'click', '#main-menu .search-link', (e) =>
      e.preventDefault()
      @showSearchBox e.currentTarget
      return


  setPostModerateCount: =>
    pending = parseInt Cookies.get("mod_pending")
    return unless pending > 0

    link = @menu.find(".moderate")
    link
      .text("#{link.text()} (#{pending})")
      .addClass "bolded"


  setHighlight: =>
    @menu
      .find(".#{@menu.data "controller"}")
      .addClass "current-menu"


  showHelpItem: =>
    @menu
      .find(".help-item.#{@menu.data("controller")}")
      .show()


  showSearchBox: (elem) ->
    submenu = $(elem).parents('.submenu')
    search_box = submenu.siblings('.search-box')
    search_text_box = search_box.find('[type="text"]')

    hide = (e) ->
      search_box.hide()
      search_box.removeClass 'is_modal'
      search_text_box.removeClass 'mousetrap'
      return

    show = ->
      $('.submenu').hide()
      search_box.show()
      search_box.addClass 'is_modal'
      search_text_box.addClass('mousetrap').focus()

      document_click_event = (e) ->
        if $(e.target).parents('.is_modal').length == 0 and !$(e.target).hasClass('is_modal')
          hide e
          $(document).off 'mousedown', '*', document_click_event
        return

      $(document).on 'mousedown', '*', document_click_event
      Mousetrap.bind 'esc', hide
      return

    show()


  syncForumMenu: (reload = false) =>
    if reload
      $.get Moebooru.path('/forum.json'), { latest: 1 }, (resp) =>
        @forumMenuItems = resp
        @syncForumMenu(false)

      return

    @forumMenuItems ?= JSON.parse(document.getElementById("forum-posts-latest").text)

    last_read = JSON.parse(document.getElementById('forum-post-last-read-at').text)
    forum_menu_items = @forumMenuItems
    forum_submenu = $('li.forum ul.submenu', @menu)
    forum_items_start = forum_submenu.find('.forum-items-start').show()

    create_forum_item = (post_data) ->
      $ '<li/>', html: $('<a/>',
        href: Moebooru.path('/forum/show/' + post_data.id + '?page=' + post_data.pages)
        text: post_data.title
        title: post_data.title
        class: if post_data.updated_at > last_read then 'unread-topic' else null)

    # Reset latest topics.
    forum_items_start.nextAll().remove()
    if forum_menu_items.length > 0
      $.each forum_menu_items, (_i, post_data) ->
        forum_submenu.append create_forum_item(post_data)
        forum_items_start.show()
        return
      # Set correct class based on read/unread.
      if forum_menu_items.first().updated_at > last_read
        $('#forum-link').addClass 'forum-update'
        $('#forum-mark-all-read').show()
      else
        $('#forum-link').removeClass 'forum-update'
        $('#forum-mark-all-read').hide()
