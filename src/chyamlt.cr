require "yaml"
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
    class_property messages_path
    class_property messages_file
    @@messages_path : Path = Chyamlt.dir / "server.yml"
    @@messages_file = File.new @@messages_path, "a"

    class MessageHandler
      include HTTP::Handler

      @messages = [] of ServerMessage

      def initialize
        Dir.mkdir_p Server.messages_path.parent
        File.open Server.messages_path do |file|
          @messages = Array(ServerMessage).from_yaml file rescue [] of ServerMessage
        end
      end

      def call(context)
        Log.debug { "SERVER : MessageHandler : Parsing new messages" }
        text = IO::Sized.new(context.request.body.not_nil!, 8 * 1024).gets_to_end
        address = context.request.remote_address.to_s
        pkg = begin
          ClientPackage.from_yaml text
        rescue ex
          Log.error { "SERVER : MessageHandler : Error parsing ClientPackage : #{ex.message}" }
          return
        end

        new_messages = pkg.messages
          .select { |client_message| client_message.text.size > 0 }
          .map { |client_message| ServerMessage.new address, client_message }
        Log.info { "SERVER : MessageHandler : #{new_messages.size} new messages from client #{address} (#{pkg.saved} are already saved)" }

        if new_messages.size > 0
          Server.messages_file.print new_messages.to_yaml[4..]
          Server.messages_file.flush
          @messages += new_messages
        end

        context.response.print ServerPackage.new(@messages[pkg.saved..]).to_yaml
      end
    end

    def initialize(@host : String, @port : Int32)
      @server = HTTP::Server.new [HTTP::CompressHandler.new, MessageHandler.new]
      @address = @server.bind_tcp @host, @port
      spawn @server.listen
    end

    def close
      @server.close
    end

    def self.wipe
      File.open @@messages_path, "w" do |file|
        file.truncate
      end
    end
  end

  class Client
    @@messages_path : Path = Chyamlt.dir / "client.yml"
    @@messages_file = File.new @@messages_path, "a"
    @@input_path : Path = Chyamlt.dir / "input.yml"

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
      @@messages_file.print pkg.messages.to_yaml[4..]
      @@messages_file.flush
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
            response = @client.post "/", body: ClientPackage.new(@size, new_messages).to_yaml
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
