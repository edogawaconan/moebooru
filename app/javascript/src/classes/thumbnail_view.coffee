import DragElement from 'src/classes/drag_element'
import { sortArrayByDistance } from 'src/utils/array'
import PreloadContainer from './preload_container'

# Handle the thumbnail view, and navigation for the main view.
#
# Handle a large number (thousands) of entries cleanly.  Thumbnail nodes are created
# as needed, and destroyed when they scroll off screen.  This gives us constant
# startup time, loads thumbnails on demand, allows preloading thumbnails in advance
# by creating more nodes in advance, and keeps memory usage constant.
export default class ThumbnailView
  constructor: (container, view) ->
    @container = container
    @view = view
    @post_ids = []
    @post_frames = []
    @expanded_post_idx = null
    @centered_post_idx = null
    @centered_post_offset = 0
    @last_mouse_x = 0
    @last_mouse_y = 0
    @thumb_container_shown = true
    @allow_wrapping = true
    @thumb_preload_container = new PreloadContainer
    @unused_thumb_pool = []

    # The [first, end) range of posts that are currently inside .post-browser-posts.
    @posts_populated = [
      0
      0
    ]
    document.on 'DOMMouseScroll', @document_mouse_wheel_event
    document.on 'mousewheel', @document_mouse_wheel_event
    document.on 'viewer:displayed-image-loaded', @displayed_image_loaded_event
    document.on 'viewer:set-active-post', (e) =>
      post_id_and_frame = [
        e.memo.post_id
        e.memo.post_frame
      ]
      @set_active_post post_id_and_frame, e.memo.lazy, e.memo.center_thumbs
      return

    document.on 'viewer:show-next-post', (e) =>
      @show_next_post e.memo.prev
      return

    document.on 'viewer:scroll', (e) =>
      @scroll e.memo.left
      return

    document.on 'viewer:set-thumb-bar', (e) =>
      if e.memo.toggle
        @show_thumb_bar !@thumb_container_shown
      else
        @show_thumb_bar e.memo.set
      return

    document.on 'viewer:loaded-posts', @loaded_posts_event
    UrlHash.observe 'post-id', @hashchange_post_id
    UrlHash.observe 'post-frame', @hashchange_post_id
    new DragElement(@container, ondrag: @container_ondrag)
    Element.on window, 'resize', @window_resize_event
    @container.on 'mousemove', @container_mousemove_event
    @container.on 'mouseover', @container_mouseover_event
    @container.on 'mouseout', @container_mouseout_event
    @container.on 'click', @container_click_event
    @container.on 'dblclick', '.post-thumb,.browser-thumb-hover-overlay', @container_dblclick_event

    # Prevent the default behavior of left-clicking on the expanded thumbnail overlay.  It's
    # handled by container_click_event.
    @container.down('.browser-thumb-hover-overlay').on 'click', (event) =>
      if event.isLeftClick()
        event.preventDefault()
      return

    # For Android browsers, we're set to 150 DPI, which (in theory) scales us to a consistent UI size
    # based on the screen DPI.  This means that we can determine the physical screen size from the
    # window resolution: 150x150 is 1"x1".  Set a thumbnail scale based on this.  On a 320x480 HVGA
    # phone screen the thumbnails are about 2x too big, so set thumb_scale to 0.5.
    #
    # For iOS browsers, there's no way to set the viewport based on the DPI, so it's fixed at 1x.
    # (Note that on Retina screens the browser lies: even though we request 1x, it's actually at
    # 0.5x and our screen dimensions work as if we're on the lower-res iPhone screen.  We can mostly
    # ignore this.)  CSS inches aren't implemented (the DPI is fixed at 96), so that doesn't help us.
    # Fall back on special-casing individual iOS devices.
    @config = {}
    if navigator.userAgent.indexOf('iPad') != -1
      @config.thumb_scale = 1.0
    else if navigator.userAgent.indexOf('iPhone') != -1 or navigator.userAgent.indexOf('iPod') != -1
      @config.thumb_scale = 0.5
    else if navigator.userAgent.indexOf('Android') != -1

      # We may be in landscape or portrait; use out the narrower dimension.
      width = Math.min(window.innerWidth, window.innerHeight)

      # Scale a 320-width screen to 0.5, up to 1.0 for a 640-width screen.  Remember
      # that this width is already scaled by the DPI of the screen due to target-densityDpi,
      # so these numbers aren't actually real pixels, and this scales based on the DPI
      # and size of the screen rather than the pixel count.
      @config.thumb_scale = width / 640
      console.debug 'Unclamped thumb scale: ' + @config.thumb_scale

      # Clamp to [0.5,1.0].
      @config.thumb_scale = Math.min(@config.thumb_scale, 1.0)
      @config.thumb_scale = Math.max(@config.thumb_scale, 0.5)
      console.debug 'startup, window size: ' + window.innerWidth + 'x' + window.innerHeight
    else

      # Unknown device, or not a mobile device.
      @config.thumb_scale = 1.0
    console.debug 'Thumb scale: ' + @config.thumb_scale
    @config_changed()

    # Send the initial viewer:thumb-bar-changed event.
    @thumb_container_shown = false
    @show_thumb_bar true
    return

  window_resize_event: (e) =>
    if e.stopped
      return
    if @thumb_container_shown
      @center_on_post_for_scroll @centered_post_idx
    return

  # Show the given posts.  If extending is true, post_ids are meant to extend a previous
  # search; attempt to continue where we left off.
  loaded_posts_event: (event) =>
    post_ids = event.memo.post_ids
    old_post_ids = @post_ids
    old_centered_post_idx = @centered_post_idx
    @remove_all_posts()

    # Filter blacklisted posts.
    post_ids = post_ids.reject(Post.is_blacklisted)
    @post_ids = []
    @post_frames = []
    for postId in post_ids
      post = Post.posts.get(postId)
      if post.frames.length > 0
        for _frame, frameIdx in post.frames
          console.log 'hey'
          @post_ids.push postId
          @post_frames.push frameIdx
      else
        @post_ids.push postId
        @post_frames.push -1
    @allow_wrapping = !event.memo.can_be_extended_further

    # Show the results box or "no results".  Do this before updating the results box to make sure
    # the results box isn't hidden when we update, which will make offsetLeft values inside it zero
    # and break things.  If the reason we have no posts is because we didn't do a search at all,
    # don't show no-results.
    @container.down('.post-browser-no-results').show event.memo.tags? and @post_ids.length == 0
    @container.down('.post-browser-posts').show @post_ids.length != 0
    if event.memo.extending

      # We're extending a previous search with more posts.  The new post list we get may
      # not line up with the old one: the post we're focused on may no longer be in the
      # search, or may be at a different index.
      #
      # Find a nearby post in the new results.  Start searching at the post we're already
      # centered on.  If that doesn't match, move outwards from there.  Only look forward
      # a little bit, or we may match a post that was never seen and jump forward too far
      # in the results.
      post_id_search_order = sortArrayByDistance(old_post_ids.slice(0, old_centered_post_idx + 3), old_centered_post_idx)
      initial_post_id = null
      i = 0
      while i < post_id_search_order.length
        post_id_to_search = post_id_search_order[i]
        post = Post.posts.get(post_id_to_search)
        if post?
          initial_post_id = post.id
          break
        ++i
      console.debug 'center-on-' + initial_post_id

      # If we didn't find anything that matched, go back to the start.

      if !initial_post_id?
        @centered_post_offset = 0
        initial_post_id = new_post_ids[0]
      center_on_post_idx = @post_ids.indexOf(initial_post_id)
      @center_on_post_for_scroll center_on_post_idx
    else

      # A new search has completed.
      #
      # results_mode can be one of the following:
      #
      # "center-on-first"
      # Don't change the active post.  Center the results on the first result.  This is used
      # when performing a search by clicking on a tag, where we don't want to center on the
      # post we're on (since it'll put us at some random spot in the results when the user
      # probably wants to browse from the beginning), and we don't want to change the displayed
      # post either.
      #
      # "center-on-current"
      # Don't change the active post.  Center the results on the existing current item,
      # if possible.  This is used when we want to show a new search without disrupting the
      # shown post, such as the "child posts" link in post info, and when loading the initial
      # URL hash when we start up.
      #
      # "jump-to-first"
      # Set the active post to the first result, and center on it.  This is used after making
      # a search in the tags box.
      results_mode = event.memo.load_options.results_mode or 'center-on-current'
      initial_post_id_and_frame = undefined
      if results_mode == 'center-on-first' or results_mode == 'jump-to-first'
        initial_post_id_and_frame = [
          @post_ids[0]
          @post_frames[0]
        ]
      else
        initial_post_id_and_frame = @get_current_post_id_and_frame()
      center_on_post_idx = @get_post_idx(initial_post_id_and_frame)
      if !center_on_post_idx?
        center_on_post_idx = 0
      @centered_post_offset = 0
      @center_on_post_for_scroll center_on_post_idx

      # If no post is currently displayed and we just completed a search, set the current post.
      # This happens when first initializing; we wait for the first search to complete to retrieve
      # info about the post we're starting on, instead of making a separate query.
      if results_mode == 'jump-to-first' or !@view.wanted_post_id?
        @set_active_post initial_post_id_and_frame, false, false, true
    if !event.memo.tags?

      # If tags is null then no search has been done, which means we're on a URL
      # with a post ID and no search, eg. "/post/browse#12345".  Hide the thumb
      # bar, so we'll just show the post.
      @show_thumb_bar false
    return

  container_ondrag: (e) =>
    @centered_post_offset -= e.dX
    @center_on_post_for_scroll @centered_post_idx
    return

  container_mouseover_event: (event) =>
    li = $(event.target)
    if !li.hasClassName('.post-thumb')
      li = li.up('.post-thumb')
    if li
      @expand_post li.post_idx
    return

  container_mouseout_event: (event) =>
    # If the mouse is leaving the hover overlay, hide it.
    target = $(event.target)
    if !target.hasClassName('.browser-thumb-hover-overlay')
      target = target.up('.browser-thumb-hover-overlay')
    if target
      @expand_post null
    return

  hashchange_post_id: =>
    post_id_and_frame = @get_current_post_id_and_frame()
    if !post_id_and_frame[0]?
      return

    # If we're already displaying this post, ignore the hashchange.  Don't center on the
    # post if this is just a side-effect of clicking a post, rather than the user actually
    # changing the hash.
    post_id = post_id_and_frame[0]
    post_frame = post_id_and_frame[1]
    if post_id == @view.displayed_post_id and post_frame == @view.displayed_post_frame
      #    debug("ignored-hashchange");
      return
    new_post_idx = @get_post_idx(post_id_and_frame)
    @centered_post_offset = 0
    @center_on_post_for_scroll new_post_idx
    @set_active_post post_id_and_frame, false, false, true
    return

  # Search for the given post ID and frame in the current search results, and return its
  # index.  If the given post isn't in post_ids, return null.
  get_post_idx: (post_id_and_frame) ->
    post_id = post_id_and_frame[0]
    post_frame = post_id_and_frame[1]
    post_idx = @post_ids.indexOf(post_id)
    if post_idx == -1
      return null
    if post_frame == -1
      return post_idx

    # A post-frame is specified.  Search for a matching post-id and post-frame.  We assume
    # here that all frames for a post are grouped together in post_ids.
    post_frame_idx = post_idx
    while post_frame_idx < @post_ids.length and @post_ids[post_frame_idx] == post_id
      if @post_frames[post_frame_idx] == post_frame
        return post_frame_idx
      ++post_frame_idx

    # We found a matching post, but not a matching frame.  Return the post.
    post_idx

  # Return the post and frame that's currently being displayed in the main view, based
  # on the URL hash.  If no post is displayed and no search results are available,
  # return [null, null].
  get_current_post_id_and_frame: ->
    post_id = UrlHash.get('post-id')
    if !post_id?
      if @post_ids.length == 0
        return [
          null
          null
        ]
      else
        return [
          @post_ids[0]
          @post_frames[0]
        ]
    post_id = parseInt(post_id)
    post_frame = UrlHash.get('post-frame')
    # If no frame is set, attempt to resolve the post_frame we'll display, if the post data
    # is already loaded.  Otherwise, post_frame will remain null.
    if !post_frame?
      post_frame = @view.get_default_post_frame(post_id)
    [
      post_id
      post_frame
    ]

  # Track the mouse cursor when it's within the container.
  container_mousemove_event: (e) =>
    x = e.pointerX() - (document.documentElement.scrollLeft)
    y = e.pointerY() - (document.documentElement.scrollTop)
    @last_mouse_x = x
    @last_mouse_y = y
    return

  document_mouse_wheel_event: (event) =>
    event.stop()
    val = undefined
    if event.wheelDelta
      val = event.wheelDelta
    else if event.detail
      val = -event.detail
    if @thumb_container_shown
      document.fire 'viewer:scroll', left: val >= 0
    else
      document.fire 'viewer:show-next-post', prev: val >= 0
    return

  # Set the post that's shown in the view.  The thumbs will be centered on the post
  # if center_thumbs is true.  See BrowserView.prototype.set_post for an explanation
  # of no_hash_change.
  set_active_post: (post_id_and_frame, lazy, center_thumbs, no_hash_change, replace_history) ->
    # If no post is specified, do nothing.  This will happen if a search returns
    # no results.
    if !post_id_and_frame[0]?
      return
    @view.set_post post_id_and_frame[0], post_id_and_frame[1], lazy, no_hash_change, replace_history
    if center_thumbs
      post_idx = @get_post_idx(post_id_and_frame)
      @centered_post_offset = 0
      @center_on_post_for_scroll post_idx
    return

  set_active_post_idx: (post_idx, lazy, center_thumbs, no_hash_change, replace_history) ->
    if !post_idx?
      return
    post_id = @post_ids[post_idx]
    post_frame = @post_frames[post_idx]
    @set_active_post [
      post_id
      post_frame
    ], lazy, center_thumbs, no_hash_change, replace_history
    return

  show_next_post: (prev) ->
    if @post_ids.length == 0
      return
    current_idx = @get_post_idx([
      @view.wanted_post_id
      @view.wanted_post_frame
    ])

    # If the displayed post isn't in the thumbnails and we're changing posts, start
    # at the beginning.
    if !current_idx?
      current_idx = 0
    add = if prev then -1 else +1
    if @post_frames[current_idx] != @view.wanted_post_frame and add == +1
      # We didn't find an exact match for the frame we're displaying, which usually means
      # we viewed a post frame, and then the user changed the view to the main post, and
      # the main post isn't in the thumbnails.
      #
      # It's strange to be on the main post, to hit pgdn, and to end up on the second frame
      # because the nearest match was the first frame.  Instead, we should end up on the first
      # frame.  To do that, just don't add anything to the index.
      console.debug 'Snapped the display to the nearest frame'
      if add == +1
        add = 0
    new_idx = current_idx
    new_idx += add
    new_idx += @post_ids.length
    new_idx %= @post_ids.length
    wrapped = prev and new_idx > current_idx or !prev and new_idx < current_idx
    if wrapped

      # Only allow wrapping over the edge if we've already expanded the results.
      if !@allow_wrapping
        return
      if !@thumb_container_shown and prev
        notice 'Continued from the end'
      else if !@thumb_container_shown and !prev
        notice 'Starting over from the beginning'
    @set_active_post_idx new_idx, true, true, false, true
    return

  # Scroll the thumbnail view left or right.  Don't change the displayed post.
  scroll: (left) ->
    # There's no point in scrolling the list if it's not visible.
    if !@thumb_container_shown
      return
    new_idx = @centered_post_idx

    # If we're not centered on the post, and we're moving towards the center,
    # don't jump past the post.
    if @centered_post_offset > 0 and left
      # do nothing
    else if @centered_post_offset < 0 and !left
      # do nothing
    else
      new_idx += if left then -1 else +1
    # Snap to the nearest post.
    @centered_post_offset = 0

    # Wrap the new index.

    if new_idx < 0
      # Only allow scrolling over the left edge if we've already expanded the results.
      if !@allow_wrapping
        new_idx = 0
      else
        new_idx = @post_ids.length - 1
    else if new_idx >= @post_ids.length
      if !@allow_wrapping
        new_idx = @post_ids.length - 1
      else
        new_idx = 0
    @center_on_post_for_scroll new_idx
    return

  # Hide the hovered post, if any, call center_on_post(post_idx), then hover over the correct post again.
  center_on_post_for_scroll: (post_idx) ->
    if @thumb_container_shown
      @expand_post null
    @center_on_post post_idx

    # Now that we've re-centered, we need to expand the correct image.  Usually, we can just
    # wait for the mouseover event to fire, since we hid the expanded thumb overlay and the
    # image underneith it is now under the mouse.  However, browsers are badly broken here.
    # Opera doesn't fire mouseover events when the element under the cursor is hidden.  FF
    # fires the mouseover on hide, but misses the mouseout when the new overlay is shown, so
    # the next time it's hidden mouseover events are lost.
    #
    # Explicitly figure out which item we're hovering over and expand it.
    if @thumb_container_shown
      element = document.elementFromPoint(@last_mouse_x, @last_mouse_y)
      element = $(element)
      if element
        li = element.up('.post-thumb')
        if li
          @expand_post li.post_idx
    return

  remove_post: (right) ->
    if @posts_populated[0] == @posts_populated[1]
      return false

    # none to remove
    node = @container.down('.post-browser-posts')
    if right
      --@posts_populated[1]
      node_to_remove = node.lastChild
    else
      ++@posts_populated[0]
      node_to_remove = node.firstChild

    # Remove the thumbnail that's no longer visible, and put it in unused_thumb_pool
    # so we can reuse it later.  This won't grow out of control, since we'll always use
    # an item from the pool if available rather than creating a new one.
    item = node.removeChild(node_to_remove)
    @unused_thumb_pool.push item
    true

  remove_all_posts: ->
    continue while @remove_post(true)

  # Add the next thumbnail to the left or right side.
  add_post_to_display: (right) ->
    node = @container.down('.post-browser-posts')
    if right
      post_idx_to_populate = @posts_populated[1]
      if post_idx_to_populate == @post_ids.length
        return false
      ++@posts_populated[1]
      thumb = @create_thumb(post_idx_to_populate)
      node.insertBefore thumb, null
    else
      if @posts_populated[0] == 0
        return false
      --@posts_populated[0]
      post_idx_to_populate = @posts_populated[0]
      thumb = @create_thumb(post_idx_to_populate)
      node.insertBefore thumb, node.firstChild
    true

  # Fill the container so post_idx is visible.
  populate_post: (post_idx) ->
    if @is_post_idx_shown(post_idx)
      return

    # If post_idx is on the immediate border of what's already displayed, add it incrementally, and
    # we'll cull extra posts later.  Otherwise, clear all of the posts and populate from scratch.
    if post_idx == @posts_populated[1]
      @add_post_to_display true
      return
    else if post_idx == @posts_populated[0]
      @add_post_to_display false
      return

    # post_idx isn't on the boundary, so we're jumping posts rather than scrolling.
    # Clear the container and start over.
    @remove_all_posts()
    node = @container.down('.post-browser-posts')
    thumb = @create_thumb(post_idx)
    node.appendChild thumb
    @posts_populated[0] = post_idx
    @posts_populated[1] = post_idx + 1
    return

  is_post_idx_shown: (post_idx) ->
    if post_idx >= @posts_populated[1]
      return false
    post_idx >= @posts_populated[0]

  # Return the total width of all thumbs to the left or right of post_idx, not
  # including itself.
  get_width_adjacent_to_post: (post_idx, right) ->
    post = $('p' + post_idx)
    if right
      rightmost_node = post.parentNode.lastChild
      if rightmost_node == post
        return 0
      right_edge = rightmost_node.offsetLeft + rightmost_node.offsetWidth
      center_post_right_edge = post.offsetLeft + post.offsetWidth
      right_edge - center_post_right_edge
    else
      post.offsetLeft

  # Center the thumbnail strip on post_idx.  If post_id isn't in the display, do nothing.
  # Fire viewer:need-more-thumbs if we're scrolling near the edge of the list.
  center_on_post: (post_idx) ->
    if !@post_ids
      console.debug 'unexpected: center_on_post has no post_ids'
      return
    post_id = @post_ids[post_idx]
    if !Post.posts.get(post_id)?
      return
    if post_idx > @post_ids.length * 3 / 4

      # We're coming near the end of the loaded posts, so load more.  We may be currently
      # in the middle of setting up the post; defer this, so we finish what we're doing first.
      (->
        document.fire 'viewer:need-more-thumbs', view: this
        return
      ).defer()
    @centered_post_idx = post_idx

    # If we're not expanded, we can't figure out how to center it since we'll have no width.
    # Also, don't cause thumbnails to be loaded if we're hidden.  Just set centered_post_idx,
    # and we'll come back here when we're displayed.
    if !@thumb_container_shown
      return

    # If centered_post_offset is high enough to put the actual center post somewhere else,
    # adjust it towards zero and change centered_post_idx.  This keeps centered_post_idx
    # pointing at the item that's actually centered.
    loop
      post = $('p' + @centered_post_idx)
      if !post
        break
      pos = post.offsetWidth / 2 + @centered_post_offset
      if pos >= 0 and pos < post.offsetWidth
        break
      next_post_idx = @centered_post_idx + (if @centered_post_offset > 0 then +1 else -1)
      next_post = $('p' + next_post_idx)
      if !next_post?
        break
      current_post_center = post.offsetLeft + post.offsetWidth / 2
      next_post_center = next_post.offsetLeft + next_post.offsetWidth / 2
      distance = next_post_center - current_post_center
      @centered_post_offset -= distance
      @centered_post_idx = next_post_idx
      post_idx = @centered_post_idx
      break
    @populate_post post_idx

    # Make sure that we have enough posts populated around the one we're centering
    # on to fill the display.  If we have too many nodes, remove some.
    direction = 0
    while direction < 2
      right = ! !direction

      # We need at least this.container.offsetWidth/2 in each direction.  Load a little more, to
      # reduce flicker.
      minimum_distance = @container.offsetWidth / 2
      minimum_distance *= 1.25
      maximum_distance = minimum_distance + 500
      loop
        added = false
        width = @get_width_adjacent_to_post(post_idx, right)

        # If we're offset to the right then we need more data to the left, and vice versa.
        width += @centered_post_offset * (if right then -1 else +1)
        if width < 0
          width = 1
        if width < minimum_distance

          # We need another post.  Stop if there are no more posts to add.
          if !@add_post_to_display(right)
            break
          added = false
        else if width > maximum_distance

          # We have a lot of posts off-screen.  Remove one.

          @remove_post right

          # Sanity check: we should never add and remove in the same direction.  If this
          # happens, the distance between minimum_distance and maximum_distance may be less
          # than the width of a single thumbnail.
          if added
            alert 'error'
            break
        else
          break
      ++direction
    @preload_thumbs()

    # We always center the thumb.  Don't clamp to the edge when we're near the first or last
    # item, so we always have empty space on the sides for expanded landscape thumbnails to
    # be visible.
    thumb = $('p' + post_idx)
    center_on_position = @container.offsetWidth / 2
    shift_pixels_right = center_on_position - (thumb.offsetWidth / 2) - (thumb.offsetLeft)
    shift_pixels_right -= @centered_post_offset
    shift_pixels_right = Math.round(shift_pixels_right)
    node = @container.down('.post-browser-scroller')
    node.setStyle left: shift_pixels_right + 'px'
    return

  # Preload thumbs on the boundary of what's actually displayed.
  preload_thumbs: ->
    post_idxs = []
    i = 0
    while i < 5
      preload_post_idx = @posts_populated[0] - i - 1
      if preload_post_idx >= 0
        post_idxs.push preload_post_idx
      preload_post_idx = @posts_populated[1] + i
      if preload_post_idx < @post_ids.length
        post_idxs.push preload_post_idx
      ++i

    # Remove any preloaded thumbs that are no longer in the preload list.
    for element in [...@thumb_preload_container.getAll()]
      post_idx = element.post_idx

      if post_idxs.indexOf(post_idx) != -1
        # The post is staying loaded.  Clear the value in post_idxs, so we don't load it
        # again down below.
        post_idxs[post_idx] = null
        continue

      # The post is no longer being preloaded.  Remove the preload.
      @thumb_preload_container.cancelPreload element

    # Add new preloads.
    i = 0
    while i < post_idxs.length
      post_idx = post_idxs[i]
      if !post_idx?
        ++i
        continue
      post_id = @post_ids[post_idx]
      post = Post.posts.get(post_id)
      post_frame = @post_frames[post_idx]
      url = undefined
      if post_frame != -1
        url = post.frames[post_frame].preview_url
      else
        url = post.preview_url
      element = @thumb_preload_container.preload(url)
      element.post_idx = post_idx
      ++i
    return

  expand_post: (post_idx) ->
    # Thumbs on click for touchpads doesn't make much sense anyway--touching the thumb causes it
    # to be loaded.  It also triggers a bug in iPhone WebKit (covering up the original target of
    # a mouseover during the event seems to cause the subsequent click event to not be delivered).
    # Just disable hover thumbnails for touchscreens.
    if Prototype.BrowserFeatures.Touchscreen
      return
    if !@thumb_container_shown
      return
    post_id = @post_ids[post_idx]
    overlay = @container.down('.browser-thumb-hover-overlay')
    overlay.hide()
    overlay.down('IMG').src = Vars.asset['blank.gif']
    @expanded_post_idx = post_idx
    if !post_idx?
      return
    post = Post.posts.get(post_id)
    if post.status == 'deleted'
      return
    thumb = $('p' + post_idx)
    bottom = @container.down('.browser-bottom-bar').offsetHeight
    overlay.style.bottom = bottom + 'px'
    post_frame = @post_frames[post_idx]
    image_width = undefined
    image_url = undefined
    if post_frame != -1
      frame = post.frames[post_frame]
      image_width = frame.preview_width
      image_url = frame.preview_url
    else
      image_width = post.actual_preview_width
      image_url = post.preview_url
    left = thumb.cumulativeOffset().left - (image_width / 2) + thumb.offsetWidth / 2
    overlay.style.left = left + 'px'

    # If the hover thumbnail overflows the right edge of the viewport, it'll extend the document and
    # allow scrolling to the right, which we don't want.  overflow: hidden doesn't fix this, since this
    # element is absolutely positioned.  Set the max-width to clip the right side of the thumbnail if
    # necessary.
    max_width = document.viewport.getDimensions().width - left
    overlay.style.maxWidth = max_width + 'px'
    overlay.href = '/post/browse#' + post.id + @view.post_frame_hash(post, post_frame)
    overlay.down('IMG').src = image_url
    overlay.show()
    return

  create_thumb: (post_idx) ->
    post_id = @post_ids[post_idx]
    post_frame = @post_frames[post_idx]
    post = Post.posts.get(post_id)

    # Reuse thumbnail blocks that are no longer in use, to avoid WebKit memory leaks: it
    # doesn't like creating and deleting lots of images (or blocks with images inside them).
    #
    # Thumbnails are hidden until they're loaded, so we don't show ugly load-borders.  This
    # also keeps us from showing old thumbnails before the new image is loaded.  Use visibility:
    # hidden, not display: none, or the size of the image won't be defined, which breaks
    # center_on_post.
    if @unused_thumb_pool.length == 0
      div = '<div class="inner">' + '<a class="thumb" tabindex="-1">' + '<img alt="" class="preview" onload="this.style.visibility = \'visible\';">' + '</a>' + '</div>'
      item = $(document.createElement('li'))
      item.innerHTML = div
      item.className = 'post-thumb'
    else
      item = @unused_thumb_pool.pop()
    item.id = 'p' + post_idx
    item.post_idx = post_idx
    item.down('A').href = '/post/browse#' + post.id + @view.post_frame_hash(post, post_frame)

    # If the image is already what we want, then leave it alone.  Setting it to what it's
    # already set to won't necessarily cause onload to be fired, so it'll never be set
    # back to visible.
    img = item.down('IMG')
    url = undefined
    if post_frame != -1
      url = post.frames[post_frame].preview_url
    else
      url = post.preview_url
    if img.src != url
      img.style.visibility = 'hidden'
      img.src = url
    @set_thumb_dimensions item
    item

  set_thumb_dimensions: (li) =>
    post_idx = li.post_idx
    post_id = @post_ids[post_idx]
    post_frame = @post_frames[post_idx]
    post = Post.posts.get(post_id)
    width = undefined
    height = undefined
    if post_frame != -1
      frame = post.frames[post_frame]
      width = frame.preview_width
      height = frame.preview_height
    else
      width = post.actual_preview_width
      height = post.actual_preview_height
    width *= @config.thumb_scale
    height *= @config.thumb_scale

    # This crops blocks that are too wide, but doesn't pad them if they're too
    # narrow, since that creates odd spacing.
    #
    # If the height of this block is changed, adjust .post-browser-posts-container in
    # config_changed.
    block_size = [
      Math.min(width, 200 * @config.thumb_scale)
      200 * @config.thumb_scale
    ]
    crop_left = Math.round((width - (block_size[0])) / 2)
    pad_top = Math.max(0, block_size[1] - height)
    inner = li.down('.inner')
    inner.actual_width = block_size[0]
    inner.actual_height = block_size[1]
    inner.setStyle
      width: block_size[0] + 'px'
      height: block_size[1] + 'px'
    img = inner.down('img')
    img.width = width
    img.height = height
    img.setStyle
      marginTop: pad_top + 'px'
      marginLeft: -crop_left + 'px'
    return

  config_changed: ->

    # Adjust the size of the container to fit the thumbs at the current scale.  They're the
    # height of the thumb block, plus ten pixels for padding at the top and bottom.
    container_height = 200 * @config.thumb_scale + 10
    @container.down('.post-browser-posts-container').setStyle height: container_height + 'px'
    @container.select('LI.post-thumb').each @set_thumb_dimensions
    @center_on_post_for_scroll @centered_post_idx
    return

  # Handle clicks and doubleclicks on thumbnails.  These events are handled by
  # the container, so we don't need to put event handlers on every thumb.
  container_click_event: (event) =>

    # Ignore the click if it was stopped by the DragElement.

    if event.stopped
      return
    if $(event.target).up('.browser-thumb-hover-overlay')

      # The hover overlay was clicked.  When the user clicks a thumbnail, this is
      # usually what happens, since the hover overlay covers the actual thumbnail.
      @set_active_post_idx @expanded_post_idx
      event.preventDefault()
      return
    li = $(event.target).up('.post-thumb')
    if !li?
      return

    # An actual thumbnail was clicked.  This can happen if we don't have the expanded
    # thumbnails for some reason.
    event.preventDefault()
    @set_active_post_idx li.post_idx
    return

  container_dblclick_event: (event) =>
    if event.button
      return
    event.preventDefault()
    @show_thumb_bar false
    return

  show_thumb_bar: (shown) ->
    if @thumb_container_shown == shown
      return
    @thumb_container_shown = shown
    @container.show shown

    # If the centered post was changed while we were hidden, it wasn't applied by
    # center_on_post, so do it now.
    @center_on_post_for_scroll @centered_post_idx
    document.fire 'viewer:thumb-bar-changed',
      shown: @thumb_container_shown
      height: if @thumb_container_shown then @container.offsetHeight else 0
    return

  # Return the next or previous post, wrapping around if necessary.
  get_adjacent_post_idx_wrapped: (post_idx, next) ->
    post_idx += if next then +1 else -1
    post_idx = (post_idx + @post_ids.length) % @post_ids.length
    post_idx

  displayed_image_loaded_event: (event) =>
    # If we don't have a loaded search, then we don't have any nearby posts to preload.

    if !@post_ids?
      return
    post_id = event.memo.post_id
    post_frame = event.memo.post_frame
    post_idx = @get_post_idx([
      post_id
      post_frame
    ])
    if !post_idx?
      return

    # The image in the post we're displaying is finished loading.
    #
    # Preload the next and previous posts.  Normally, one or the other of these will
    # already be in cache.
    #
    # Include the current post in the preloads, so if we switch from a frame back to
    # the main image, the frame itself will still be loaded.
    post_ids_to_preload = []
    post_ids_to_preload.push [
      @post_ids[post_idx]
      @post_frames[post_idx]
    ]
    adjacent_post_idx = @get_adjacent_post_idx_wrapped(post_idx, true)
    if adjacent_post_idx?
      post_ids_to_preload.push [
        @post_ids[adjacent_post_idx]
        @post_frames[adjacent_post_idx]
      ]
    adjacent_post_idx = @get_adjacent_post_idx_wrapped(post_idx, false)
    if adjacent_post_idx?
      post_ids_to_preload.push [
        @post_ids[adjacent_post_idx]
        @post_frames[adjacent_post_idx]
      ]
    @view.preload post_ids_to_preload
    return
