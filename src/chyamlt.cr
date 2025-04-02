require "yaml"
require "json"
require "http"
require "http/server"
require "http/server/handler"
require "uri"

module Chyamlt
  class_property dir
  {% if flag?(:windows) %}
    @@dir = Path.new("~", "AppData", "chyamlt").expand(home: true)
  {% else %}
    @@dir = Path.new("~", ".config", "chyamlt").expand(home: true)
  {% end %}

  class ServerMessage
    include YAML::Serializable

    getter received : Time
    getter sender : String
    getter text : String

    def initialize(@sender, client_message : ClientMessage)
      @received = Time.utc
      @text = client_message.text
    end
  end

  class ClientMessage
    include YAML::Serializable

    getter text : String

    def initialize(@text)
    end
  end

  class ClientPackage
    include YAML::Serializable

    getter saved : Int32 | Int64
    getter messages : Array(ClientMessage)

    def initialize(@saved, @messages)
    end
  end

  class ServerPackage
    include YAML::Serializable

    getter messages : Array(ServerMessage)

    def initialize(@messages)
    end
  end

  class Server
    class_property dir
    class_property messages_path
    @@dir : Path = Chyamlt.dir / "server"
    @@messages_path : Path = @@dir / "messages.yml"

    class Bot
      class Config
        include YAML::Serializable

        getter token : String
        getter key : String

        def initialize(@token, @key)
        end
      end

      getter(address) { URI.parse "https://api.telegram.org/bot#{@config.token}" }
      getter(client) { HTTP::Client.new address }

      def initialize(@config : Config)
        spawn run
      end

      def run
        loop do
          response = client.get "getUpdates", body: {"timeout" => 5, "allowed_updates" => ["message"]}.to_json
          JSON.parse(response.body).as_a.each do |update|
            user_id = update["message"]["from"]["id"].as_i
            user_token = OpenSSL::HMAC.hexdigest OpenSSL::Algorithm::SHA256, @config.key, user_id.to_s
          end
        end
      end
    end

    class Config
      include YAML::Serializable

      getter host : String
      getter port : Int32
      getter bot : Bot::Config

      def initialize(@host, @port, @bot)
      end

      def self.from_file_or_default(path : Path = Server.dir / "config.yml")
        if !File.exists? path
          Dir.mkdir_p path.parent
          File.write path, Config.new("localhost", 3000, Bot::Config.new("put your bot token here", "secret key for generating users tokens")).to_yaml
        end
        Config.from_yaml File.new path
      end
    end

    class MessageHandler
      include HTTP::Handler

      @messages = [] of ServerMessage

      def initialize
        Dir.mkdir_p Server.messages_path.parent
        if File.exists? Server.messages_path
          @messages = Array(ServerMessage).from_yaml File.new Server.messages_path rescue [] of ServerMessage
        end
        @messages_file = File.new Server.messages_path, "a"
      end

      def call(context)
        Log.debug { "SERVER : MessageHandler : Parsing new messages" }
        text = IO::Sized.new(context.request.body.not_nil!, 8 * 1024).gets_to_end
        address = context.request.remote_address.to_s
        pkg = begin
          ClientPackage.from_yaml text
        rescue ex
          Log.error { "SERVER : MessageHandler : Error parsing ClientPackage : #{ex.message}" }
          context.response.status_code = 400
          return
        end

        new_messages = pkg.messages
          .select { |client_message| client_message.text.size > 0 }
          .map { |client_message| ServerMessage.new address, client_message }
        Log.info { "SERVER : MessageHandler : #{new_messages.size} new messages from client #{address} (#{pkg.saved} are already saved)" }

        if new_messages.size > 0
          @messages_file.print new_messages.to_yaml[4..]
          @messages_file.flush
          @messages += new_messages
        end

        context.response.print ServerPackage.new(@messages[pkg.saved..]).to_yaml
        context.response.headers["Content-Type"] = "application/x-yaml"
      end
    end

    def initialize(@config : Config = Config.from_file_or_default)
      @server = HTTP::Server.new [HTTP::CompressHandler.new, MessageHandler.new]
      @address = @server.bind_tcp config.host, config.port
      @bot = Bot.new @config.bot
      spawn @server.listen
    end

    def close
      @server.close
    end

    def self.wipe
      return if !File.exists? @@messages_path
      File.open @@messages_path, "w" do |file|
        file.truncate
      end
    end
  end

  class Client
    @@dir : Path = Chyamlt.dir / "client"
    @@messages_path : Path = @@dir / "messages.yml"
    @@input_path : Path = @@dir / "input.yml"

    @size = 0

    def initialize(@host : String, @port : Int32)
      @address = "http://#{@host}:#{@port}"
      @client = HTTP::Client.new URI.parse @address
      @client.compress = true

      Dir.mkdir_p @@messages_path.parent
      Dir.mkdir_p @@input_path.parent
      File.each_line @@messages_path do |line|
        @size += 1 if line.starts_with? "- "
      end
      @messages_file = File.new @@messages_path, "a"
    end

    protected def add_messages(response_body : String)
      Log.debug { "CLIENT : Parsing received messages" }
      pkg = begin
        ServerPackage.from_yaml response_body
      rescue ex
        Log.error { "CLIENT : Error parsing ServerPackage : #{ex.message}" }
        return
      end
      Log.info { "CLIENT : #{pkg.messages.size} messages from server #{@address}" }

      @size += pkg.messages.size
      @messages_file.print pkg.messages.to_yaml[4..]
      @messages_file.flush
      File.delete @@input_path
    end

    def monitor
      last_check : Time? = nil
      loop do
        if File.exists?(@@input_path) && (!last_check || File.info(@@input_path).modification_time > last_check)
          Log.debug { "CLIENT : Reading new messages" }
          new_messages = begin
            Array(ClientMessage).from_yaml File.read @@input_path
          rescue ex
            Log.error { "CLIENT : Error parsing Array(ClientMessage) : #{ex.message}" }
          end
          if new_messages
            Log.debug { "CLIENT : Sending new messages" }
            response = @client.post "/", {"Content-Type" => "application/x-yaml"}, ClientPackage.new(@size, new_messages).to_yaml
            Log.debug { "CLIENT : Sent new messages" }
            if !response.success?
              Log.error { "CLIENT : Non-success response #{response.status}" }
            else
              add_messages response.body
            end
          end
          last_check = Time.utc
          sleep 0.2.seconds
        end
      end
    end

    def close
      @client.close
    end

    def self.wipe
      @@messages.close
      File.delete @@messages_path
      File.delete @@input_path
    end
  end
end

Log.setup level: Log::Severity::Debug

# server = Chyamlt::Server.new "localhost", 3000
# client = Chyamlt::Client.new "localhost", 3000
# spawn client.monitor
# sleep
