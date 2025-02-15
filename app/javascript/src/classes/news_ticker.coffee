$ = jQuery

key = 'hide_news_ticker'

export default class NewsTicker

  constructor: ->
    $ @initialize


  initialize: =>
    @$newsTicker = $('#news-ticker')
    @newsDate = @$newsTicker.attr('data-date')

    return if @$newsTicker.attr('data-news-hide') == '1'

    @$newsTicker.find('.close-link').click @onCloseLink
    if localStorage.getItem(key) != @newsDate
      @$newsTicker.show()


  onCloseLink: (e) =>
    e.preventDefault()
    @$newsTicker.hide()
    localStorage.setItem key, @newsDate
