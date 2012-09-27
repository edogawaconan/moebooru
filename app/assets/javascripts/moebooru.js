(function ($) {
  Moebooru = {
    '__slug__': {}
  };
  Moe = $(Moebooru);

  Moebooru.addData = function (data) {
    if (data.posts)
      Moe.trigger("post:add", [data.posts]);
    if (data.tags)
      Moe.trigger("tag:add", [data.tags]);
    if (data.votes)
      Moe.trigger("vote:add", [data.votes]);
    if (data.voted_by)
      Moe.trigger("vote:add_user_list", [data.voted_by]);
    if (data.pools)
      Moe.trigger("pool:add", [data.pools]);
    if (data.pool_posts)
      Moe.trigger("pool:add_post", {
        pool_posts: data.pool_posts,
        posts: data.posts
      });
  };

  Moebooru.attach = function (key, obj) {
    Moebooru['__slug__'][key] = obj;
  };

  Moebooru.get = function (key) {
   return Moebooru['__slug__'][key];
  };

  Moebooru.request = function (url, params) {
    $.ajax({
      url: PREFIX === '/' ? url : PREFIX+url,
      type: 'POST',
      dataType: 'json',
      data: params,
      statusCode: {
        403: function () {
          notice(t('error')+': '+t('denied'));
        }
      }
    }).done(function (data) {
      Moe.trigger(url+":ready", [data]);
    }).fail(function () {
      notice(t('error'));
    });
  };

  Moebooru.path = function (url) {
    return PREFIX === '/' ? url : PREFIX + url;
  }
})(jQuery);
