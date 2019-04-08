# coding: utf-8
require 'active_record'
require 'net/http'

IGNORED_PLAYERS = [
  "Kronogenics",
  "BlueIsTrue",
  "fiordhraoi",
  "cheeseburgur101",
  "Jey",
  "jungletek",
  "Hedgy",
  "ᕈᘎᑕᒎᗩn ᙡiᗴᒪḰi",
  "Venom",
  "EpicGamer10075",
  "Altii",
  "Puςe",
  "Floof The Goof",
]

module HighScore
  def self.format_rank(rank)
    "#{rank < 10 ? '0' : ''}#{rank}"
  end

  def self.spreads(n, type, tabs)
    spreads = {}
    scores = tabs.empty? ? type.all : type.where(tab: tabs)

    scores.each do |elem|
      spread = elem.spread(n)
      if !spread.nil?
        spreads[elem.name] = spread
      end
    end

    spreads
  end

  def self.ties(type, tabs)
    ties = {}
    scores = tabs.empty? ? type.all : type.where(tab: tabs)

    scores.each do |elem|
      tie_count = elem.tie_count
      if !tie_count.nil? && tie_count > 3
        ties[elem.name] = tie_count
      end
    end

    ties
  end

  def uri(steam_id)
    URI("https://dojo.nplusplus.ninja/prod/steam/get_scores?steam_id=#{steam_id}&steam_auth=&#{self.class.to_s.downcase}_id=#{self.id.to_s}")
  end

  def update_steam_id
    User.where.not(steam_id: nil).each do |u|
      response = Net::HTTP.get(uri(u.steam_id))
      if response != '-1337'
        set_last_steam_id(u.steam_id)
        return response
      end
    end

    return '-1337'
  end

  def get_scores
    begin
      response = Net::HTTP.get(uri(get_last_steam_id))
      if response == '-1337'
        response = update_steam_id
      end

      return nil if response == '-1337'
      return JSON.parse(response)['scores']
    rescue => e
      err("error getting scores: #{e}")
      retry
    end 
  end

  def update_scores(updated)
    updated = updated.select { |score| !IGNORED_PLAYERS.include?(score['user_name']) }.uniq { |score| score['user_name'] }

    ActiveRecord::Base.transaction do
      updated.each_with_index do |score, i|
        scores.find_or_create_by(rank: i)
          .update(
            score: score['score'] / 1000.0,
            player: Player.find_or_create_by(name: score['user_name']),
            tied_rank: updated.find_index { |s| s['score'] == score['score'] }
          )
      end
    end
  end

  def download_scores
    updated = get_scores

    if updated.nil?
      # TODO make this use err()
      STDERR.puts "[WARNING] [#{Time.now}] failed to retrieve scores from #{uri(get_last_steam_id)}"
      return
    end

    update_scores(updated)
  end

  def spread(n)
    scores.find_by(rank: n).spread unless !scores.exists?(rank: n)
  end

  def tie_count
    scores.take_while{ |s| s.tie }.count
  end

  def format_scores
    scores.map(&:format).join("\n")
  end

  def difference(old)
    scores.map do |score|
      oldscore = old.find { |o| o['player']['name'] == score.player.name }
      change = nil

      if oldscore
        change = {rank: oldscore['rank'] - score.rank, score: score.score - oldscore['score']}
      end

      {score: score, change: change}
    end
  end

  def format_difference(old)
    difference(old).map { |o|
      c = o[:change]
      diff = c ? "#{"++-"[c[:rank] <=> 0]}#{c[:rank].abs}, +#{"%.3f" % [c[:score]]}" : "new"
      "#{o[:score].format} (#{diff})"
    }.join("\n")
  end
end

class Level < ActiveRecord::Base
  include HighScore
  has_many :scores, as: :highscoreable
  has_many :videos, as: :highscoreable
  enum tab: [:SI, :S, :SU, :SL, :SS, :SS2]

  def format_name
    "#{longname} (#{name})"
  end
end

class Episode < ActiveRecord::Base
  include HighScore
  has_many :scores, as: :highscoreable
  has_many :videos, as: :highscoreable
  enum tab: [:SI, :S, :SU, :SL, :SS, :SS2]

  def format_name
    "#{name}"
  end

  def cleanliness
    [name, Level.where("UPPER(name) LIKE ?", name.upcase + '%').map{ |l| l.scores[0].score }.sum - scores[0].score - 360]
  end

  def ownage
    owner = scores[0].player.name
    [name, Level.where("UPPER(name) LIKE ?", name.upcase + '%').map{ |l| l.scores[0].player.name == owner }.count(true) == 5, owner]
  end
end

class Score < ActiveRecord::Base
  belongs_to :player
  belongs_to :highscoreable, polymorphic: true
  belongs_to :level, -> { where(scores: {highscoreable_type: 'Level'}) }, foreign_key: 'highscoreable_id'
  belongs_to :episode, -> { where(scores: {highscoreable_type: 'Episode'}) }, foreign_key: 'highscoreable_id'

  def self.total_scores(type, tabs, secrets)
    tabs = (tabs.empty? ? [:SI, :S, :SL, :SU, :SS, :SS2] : tabs)
    tabs = (secrets ? tabs : tabs - [:SS, :SS2])
    query = self.where(rank: 0, highscoreable_type: type.to_s)
    result = (query.includes(:level).where(levels: {tab: tabs}) + query.includes(:episode).where(episodes: {tab: tabs})).map{ |s| s.score }
    [result.sum, result.count]
  end

  def spread
    highscoreable.scores.find_by(rank: 0).score - score
  end

  def tie
    highscoreable.scores.find_by(rank: 0).score == score
  end

  def format
    "#{HighScore.format_rank(rank)}: #{player.name} (#{"%.3f" % [score]})"
  end
end

class Player < ActiveRecord::Base
  has_many :scores
  has_many :rank_histories
  has_many :points_histories
  has_many :total_score_histories
  has_one :user

  def self.rankings(&block)
    players = Player.includes(:scores).all

    players.map { |p| [p, yield(p)] }
      .sort_by { |a| -a[1] }
  end

  def self.histories(type, attrs, column)
    hist = type.where(attrs).includes(:player)

    ret = Hash.new { |h, k| h[k] = Hash.new { |h, k| h[k] = 0 } }

    hist.each do |h|
      ret[h.player.name][h.timestamp] += h.send(column)
    end

    ret
  end

  def self.rank_histories(rank, type, tabs, ties)
    attrs = {rank: rank, ties: ties}
    attrs[:highscoreable_type] = type.to_s if type
    attrs[:tab] = tabs if !tabs.empty?

    self.histories(RankHistory, attrs, :count)
  end

  def self.score_histories(type, tabs)
    attrs = {}
    attrs[:highscoreable_type] = type.to_s if type
    attrs[:tab] = tabs if !tabs.empty?

    self.histories(TotalScoreHistory, attrs, :score)
  end

  def self.points_histories(type, tabs)
    attrs = {}
    attrs[:highscoreable_type] = type.to_s if type
    attrs[:tab] = tabs if !tabs.empty?

    self.histories(PointsHistory, attrs, :points)
  end

  def scores_by_type_and_tabs(type, tabs)
    ret = type ? scores.where(highscoreable_type: type.to_s) : scores
    ret = tabs.empty? ? ret : ret.includes(:level).where(levels: {tab: tabs}) + ret.includes(:episode).where(episodes: {tab: tabs})
    ret
  end

  def top_ns(n, type, tabs, ties)
    scores_by_type_and_tabs(type, tabs).select do |s|
      (ties ? s.tied_rank : s.rank) < n
    end
  end

  def top_n_count(n, type, tabs, ties)
    top_ns(n, type, tabs, ties).count
  end

  def scores_by_rank(type, tabs)
    ret = Array.new(20, [])
    scores_by_type_and_tabs(type, tabs).group_by(&:rank).sort_by(&:first).each { |rank, scores| ret[rank] = scores }
    ret
  end

  def score_counts(tabs)
    {
      levels: scores_by_rank(Level, tabs).map(&:length).map(&:to_i),
      episodes: scores_by_rank(Episode, tabs).map(&:length).map(&:to_i)
    }
  end

  def missing_top_ns(n, type, tabs, ties)
    levels = top_ns(n, type, tabs, ties).map { |s| s.highscoreable.name }

    if type
      type.where(tab: tabs).where.not(name: levels).pluck(:name)
    else
      Level.where(tab: tabs).where.not(name: levels).pluck(:name) + Episode.where(tab: tabs).where.not(name: levels).pluck(:name)
    end
  end

  def improvable_scores(type, tabs)
    improvable = {}
    scores_by_type_and_tabs(type, tabs).each { |s| improvable[s.highscoreable.name] = s.spread }
    improvable
  end

  def points(type, tabs)
    scores_by_type_and_tabs(type, tabs).pluck(:rank).map { |rank| 20 - rank }.reduce(0, :+)
  end

  def average_points(type, tabs)
    scores = scores_by_type_and_tabs(type, tabs).pluck(:rank).map { |rank| 20 - rank }
    scores.length == 0 ? 0 : scores.reduce(0, :+).to_f / scores.length
  end

  def total_score(type, tabs)
    scores_by_type_and_tabs(type, tabs).pluck(:score).reduce(0, :+)
  end
end

class User < ActiveRecord::Base
  belongs_to :player
end

class GlobalProperty < ActiveRecord::Base
end

class RankHistory < ActiveRecord::Base
  belongs_to :player
  enum tab: [:SI, :S, :SU, :SL, :SS, :SS2]
end

class PointsHistory < ActiveRecord::Base
  belongs_to :player
  enum tab: [:SI, :S, :SU, :SL, :SS, :SS2]
end

class TotalScoreHistory < ActiveRecord::Base
  belongs_to :player
  enum tab: [:SI, :S, :SU, :SL, :SS, :SS2]
end

class Video < ActiveRecord::Base
  belongs_to :highscoreable, polymorphic: true

  def format_challenge
    return (challenge == "G++" || challenge == "?!") ? challenge : "#{challenge} (#{challenge_code})"
  end

  def format_author
    return "#{author} (#{author_tag})"
  end

  def format_description
    "#{format_challenge} by #{format_author}"
  end
end
