require "json"
require "sinatra/base"
require "github-trello/version"
require "github-trello/http"

module GithubTrello
  class Server < Sinatra::Base
    post "/posthook" do
      config, http = self.class.config, self.class.http

      if config.key?("secret")
        request.body.rewind
        payload_body = request.body.read
        verify_signature(payload_body, config["secret"], request.env['HTTP_X_HUB_SIGNATURE'])
      end

      payload = JSON.parse(params[:payload])

      board_id = config["board_ids"][payload["repository"]["name"]]
      unless board_id
        puts "[ERROR] Commit from #{payload["repository"]["name"]} but no board_id entry found in config"
        return
      end

      branch = payload["ref"].gsub("refs/heads/", "")
      if config["blacklist_branches"] and config["blacklist_branches"].include?(branch)
        return
      elsif config["whitelist_branches"] and !config["whitelist_branches"].include?(branch)
        return
      end

      payload["commits"].each do |commit|
        # Figure out the card short id
        match = commit["message"].match(/((start|case|card|close|archive|fix|finish)e?s?d? \D?([0-9]+))/i)
        next unless match and match[3].to_i > 0

        results = http.get_card(board_id, match[3].to_i)
        unless results
          puts "[ERROR] Cannot find card matching ID #{match[3]}"
          next
        end

        results = JSON.parse(results)

        # Add the commit comment
        message = "#{commit["author"]["name"]}: #{commit["message"]}\n\n#{commit["url"]}"
        message.gsub!(/^ *\[ *#{match[1]} *\].*$/, "")
        message.gsub!(/\(\)$/, "")

        # Get comments, if comment already there, do nothing
        comments = http.get_comments(results["id"])
        comments = JSON.parse(comments)
        existing_comment = comments.any? {|comment| comment["data"]["text"] == message}
        if existing_comment
          puts "Comment with text '#{message}' already exists, skipping"
          next
        end
        
        http.add_comment(results["id"], message)

        # Determine the action to take
        update_config = case match[2].downcase
          when "start" then config["on_start"]
          when "case", "card" then config["on_comment"]
          when "close", "fix", "finish" then config["on_close"]
          when "archive" then {:archive => true}
        end

        next unless update_config.is_a?(Hash)

        # Modify it if needed
        to_update = {}
        
        if update_config.key?("move_to")
          if update_config["move_to"].is_a?(Hash)
            move_to = update_config["move_to"][payload["repository"]["name"]]
          else
            move_to = update_config["move_to"]
          end

          unless results["idList"] == move_to
            to_update[:idList] = move_to
          end
        end
        
        if !results["closed"] and update_config["archive"]
          to_update[:closed] = true
        end

        unless to_update.empty?
          http.update_card(results["id"], to_update)
        end
      end

      ""
    end

    post "/deployed/:repo" do
      config, http = self.class.config, self.class.http
      if !config["on_deploy"]
        raise "Deploy triggered without a on_deploy config specified"
      elsif !config["on_close"] or !config["on_close"]["move_to"]
        raise "Deploy triggered and either on_close config missed or move_to is not set"
      end

      update_config = config["on_deploy"]

      to_update = {}
      if update_config["move_to"] and update_config["move_to"][params[:repo]]
        to_update[:idList] = update_config["move_to"][params[:repo]]
      end

      if update_config["archive"]
        to_update[:closed] = true
      end

      if config["on_close"]["move_to"].is_a?(Hash)
        target_board = config["on_close"]["move_to"][params[:repo]]
      else
        target_board = config["on_close"]["move_to"]
      end

      cards = JSON.parse(http.get_cards(target_board))
      cards.each do |card|
        http.update_card(card["id"], to_update)
      end

      ""
    end

    get "/" do
      ""
    end

    def verify_signature(payload_body, secret, github_signature)
      hmac_digest = OpenSSL::Digest.new('sha1')
      signature = 'sha1=' + OpenSSL::HMAC.hexdigest(hmac_digest, secret, payload_body)
      return halt 500, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, github_signature)
    end

    def self.config=(config)
      @config = config
      @http = GithubTrello::HTTP.new(config["oauth_token"], config["api_key"])
    end

    def self.config; @config end
    def self.http; @http end
  end
end