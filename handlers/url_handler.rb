# Use this class to debug stuff as you
# go along - e.g. dump events etc.
# options = {:ident=>"i=user", :host=>"unaffiliated/user", :nick=>"User", :message=>"this is a message", :target=>"#pookie-testing"}

#require 'curb'
require 'epitools'
require 'mechanize'
require 'cgi'
require 'logger'
require 'json'

#############################################################################
# Monkeypatches
#############################################################################

class String

  UNESCAPE_TABLE = {
    'nbsp'  => ' ',
    'ndash' => '-',
    'mdash' => '-',
    'amp'   => '&',
    'raquo' => '>>',
    'laquo' => '<<',
    'quot'  => '"',
    'micro' => 'u',
    'copy'  => '(c)',
    'trade' => '(tm)',
    'reg'   => '(R)',
    '#174'  => '(R)',
    '#8220' => '"',
    '#8221' => '"',
    '#8212' => '--',
    '#39'   => "'",
    '#8217' => "'",
  }

  def translate_html_entities
    # first pass -- let CGI have a crack at it...
    raw_title = CGI::unescapeHTML(self)

    # second pass -- fix things that won't display as ASCII...
    raw_title.gsub(/(&([\w\d#]+?);)/) do
      symbol = $2

      # remove the 0-paddng from unicode integers
      if symbol =~ /#(.+)/
        symbol = "##{$1.to_i.to_s}"
      end

      # output the symbol's irc-translated character, or a * if it's unknown
      UNESCAPE_TABLE[symbol] || '*'
    end
  end

  def to_params
    CGI.parse(self).map_values do |v|
      # CGI.parse wraps every value in an array. Unwrap them!
      if v.is_a?(Array) and v.size == 1
        v.first
      else
        v
      end
    end
  end
end

class Integer

  def to_hms
    seconds = self

    days, seconds    = seconds.divmod(86400)
    hours, seconds   = seconds.divmod(3600)
    minutes, seconds = seconds.divmod(60)

    result = "%0.2d:%0.2d" % [minutes,seconds]
    result = ("%0.2d:" % hours) + result   if hours > 0 or days > 0
    result = ("%0.2d:" % days) + result    if days > 0

    result
  end

  def commatize
    to_s.gsub(/(\d)(?=\d{3}+(?:\.|$))(\d{3}\..*)?/,'\1,\2')
  end

end

class Nokogiri::XML::Element

  def clean_text
    if inner_text
      inner_text.strip.gsub(/\s*\n+\s*/, " ").translate_html_entities
    else
      nil
    end
  end

end

class NilClass
  #
  # A simple way to make it so missing fields nils don't cause the app the explode.
  #
  def [](*args)
    nil
  end
end

class YouTubeVideo < Struct.new(
                :title,
                :thumbnails,
                :link,
                :description,
                :length,
                :user,
                :published,
                :updated,
                :rating,
                :raters,
                :keywords,
                :favorites,
                :views
              )

  def initialize(rec)

    media = rec["media$group"]

    self.title        = media["media$title"]["$t"]
    self.thumbnails   = media["media$thumbnail"].map{|r| r["url"]}
    self.link         = media["media$player"].first["url"].gsub('&feature=youtube_gdata_player','')
    self.description  = media["media$description"]["$t"]
    self.length       = media["yt$duration"]["seconds"].to_i
    self.user         = rec["author"].first["name"]["$t"]
    self.published    = DateTime.parse rec["published"]["$t"]
    self.updated      = DateTime.parse rec["updated"]["$t"]
    self.rating       = rec["gd$rating"]["average"]
    self.raters       = rec["gd$rating"]["numRaters"]
    self.keywords     = rec["media$group"]["media$keywords"]["$t"]
    self.favorites    = rec["yt$statistics"]["favoriteCount"].to_i
    self.views        = rec["yt$statistics"]["viewCount"].to_i
  end

end

module URI
  def params
    query.to_params
  end
end

#############################################################################
# Generic link info
class Mechanize::Download
  def size
    header["content-length"].to_i
  end

  def mimetype
    header["content-type"]
  end

  def link_info
    "type: \2#{mimetype}\2#{size <= 0 ? "" : ", size: \2#{size.commatize} bytes\2"}"
  end
end

#############################################################################
# Image info
class ImageParser < Mechanize::Download

  def peek(amount=4096)
    unless @result
      @result = body_io.read(amount)
      body_io.close
    end

    @result
  end

  def link_info
    tmp = Path.tempfile
    #tmp << peek
    tmp << body

    # avatar_6786.png PNG 80x80 80x80+0+0 8-bit DirectClass 15.5KB 0.000u 0:00.000
    filename, type, dimensions, *extra = `identify #{tmp}`.split

    if dimensions and type
      "image: \2#{dimensions} #{type}\2 (#{tmp.size.commatize} bytes)"
    else
      "image: \2#{mimetype}\2 (#{size.commatize} bytes)"
    end
  end

end

#############################################################################
# HTML link info
class HTMLParser < Mechanize::Page

  TITLE_RE = /<\s*?title\s*?>(.+?)<\s*?\/title\s*?>/im

  def get_title
    # Generic parser
    titles = search("title")
    if titles.any?
      title = titles.first.clean_text
      title = title[0..255] if title.length > 255
      title
    else
      nil
    end
  end

  def link_info
    p uri.to_s

    case uri.to_s
    when %r{(https?://twitter\.com/)(?:#!/)?(.+/status/\d+)}
      # Twitter parser
      newurl  = "#{$1}#{$2}"
      page    = mech.get(newurl)

      tweet   = page.at(".tweet-text").clean_text
      tweeter = page.at(".tweet")["data-screen-name"]

      "tweet: <\2@#{tweeter}\2> #{tweet}"

    when %r{(https?://twitter\.com/)(?:#!/)?([^/]+)/?$}
      newurl    = "#{$1}#{$2}"
      page      = mech.get(newurl)

      username  = $2
      fullname  = page.at("ul.entry-author li span.fn").clean_text
      followers = page.at("span#follower_count").clean_text
      following = page.at("span#following_count").clean_text
      tweets    = page.at("span#update_count").clean_text

      "tweeter: @\2#{username}\2 (\2#{fullname}\2) | tweets: \2#{tweets}\2, following: \2#{following}\2, followers: \2#{followers}\2"

    when %r{https?://(?:www\.)?github\.com/([^/]+?)/([^/]+?)$}
      watchers, forks = search("a.social-count").map(&:clean_text)

      desc     = at("#repository_description")
      desc.at("span").remove
      desc     = desc.clean_text

      "github: \2#{$1}/#{$2}\2 - #{desc} (watchers: \2#{watchers}\2, forks: \2#{forks}\2)"

    #when %r{https?://(?:www\.)?github\.com/([^/]+?)/([^/]+?)/blob/(.+)$}

    when %r{https?://(www\.)?youtube\.com/watch\?}
      #views = at("span.watch-view-count").clean_text
      #date  = at("#eow-date").clean_text
      #time  = at("span.video-time").clean_text
      #title = at("#eow-title").clean_text

      video_id = uri.params["v"]
      page     = mech.get("http://gdata.youtube.com/feeds/api/videos/#{video_id}?v=1&alt=json")
      json     = page.body.from_json

      video    = YouTubeVideo.new(json["entry"])

      views    = video.views.commatize
      date     = video.published.strftime("%Y-%m-%d")
      time     = video.length.to_hms
      title    = video.title
      rating   = video.rating ? "%0.1f" % video.rating : "?"

      "video: \2#{title}\2 (length: \2#{time}\2, views: \2#{views}\2, rating: \2#{rating}\2, posted: \2#{date}\2)"
      #"< #{title} (length: #{time}, views: #{views}, posted: #{date}) >"

    else
      if title = get_title
        "title: \2#{title}\2"
        #"< #{title} >"
      else
        nil
      end
    end
  end

  #--------------------------------------------------------------------------

  def get_title_from_html(pagedata)
    return unless TITLE_RE.match(pagedata)
    title = $1.strip.gsub(/\s*\n+\s*/, " ")
    title = unescape_title title
    title = title[0..255] if title.length > 255
    "title: \2#{title}\2"
  end

end

#############################################################################
# The Plugin
#############################################################################

class UrlHandler < Marvin::CommandHandler

  HTTP_STATUS_CODES = {
    000 => "Incomplete/Undefined error",
    201 => "Created",
    202 => "Accepted",
    203 => "Partial Information",
    204 => "Page does not contain any information",
    204 => "No response",
    206 => "Only partial content delivered",
    300 => "Page redirected",
    301 => "Permanent URL relocation",
    302 => "Temporary URL relocation",
    303 => "Temporary relocation method and URL",
    304 => "Document not modified",
    400 => "Bad request (syntax)",
    401 => "Unauthorized access (requires authentication)",
    402 => "Access forbidden (payment required)",
    403 => "Forbidden",
    404 => "URL not found",
    405 => "Method not Allowed (Most likely the result of a corrupt CGI script)",
    408 => "Request time-out",
    500 => "Internet server error",
    501 => "Functionality not implemented",
    502 => "Bad gateway",
    503 => "Service unavailable",
  }

  IGNORE_NICKS = [
    /^CIA-\d+$/,
    /^travis-ci/,
    /^buttslave/,
  ]

  #--------------------------------------------------------------------------

  ### Handle All Lines of Chat ############################

  #on_event :incoming_message, :look_for_url
  def handle_incoming_message(args)
    return if IGNORE_NICKS.any?{|pattern| args[:nick] =~ pattern}

    p args

    url_list = URI.extract(args[:message], ["http", "https", "ftp"])

    url_list.each do |url|
      logger.info "Getting info for #{url}..."

      page = agent.get(url)

      if page.respond_to? :link_info and title = page.link_info
        say title, args[:target]
        logger.info title
      else
        logger.info "Link info not found!"
      end
    end

  rescue Mechanize::ResponseCodeError, SocketError => e

    say "Error: #{e.message}"

  end

  ### Private methods... ###############################

  #--------------------------------------------------------------------------

  def agent
    @agent ||= Mechanize.new do |a|
      a.pluggable_parser["image"] = ImageParser
      a.pluggable_parser.html     = HTMLParser

      a.user_agent_alias          = "Windows IE 7"
      a.max_history               = 0
      a.log                       = Logger.new $stdout # FIXME: Assign this to the Marvin logger
      a.verify_mode               = OpenSSL::SSL::VERIFY_NONE
    end
  end

  #--------------------------------------------------------------------------

end
