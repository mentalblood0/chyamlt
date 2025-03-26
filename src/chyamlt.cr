require "yaml"
require "http/server"
require "http/web_socket"
require "uri"

module Chyamlt
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
  end

  class ClientPackage
    include YAML::Serializable

    getter saved : Int64
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

  class_property dir
  {% if flag?(:windows) %}
    @@dir = Path.new("~", "AppData", "chyamlt").expand(home: true)
  {% else %}
    @@dir = Path.new("~", ".config", "chyamlt").expand(home: true)
  {% end %}

  class Server
    @@messages_path : Path = Chyamlt.dir / "server.yml"
    @@messages_file = File.new @@messages_path, "a"

    @messages = [] of ServerMessage

    def initialize(@host : String, @port : Int32)
      Dir.mkdir_p @@messages_path.parent
      File.open @@messages_path do |file|
        @messages = Array(ServerMessage).from_yaml file rescue [] of ServerMessage
      end

      @handler = HTTP::WebSocketHandler.new do |ws, ctx|
        address = ctx.request.remote_address.to_s
        Log.info { "SERVER : Connection from client #{address}" }
        ws.on_message do |text|
          Log.debug { "SERVER : Parsing new messages" }
          pkg = begin
            ClientPackage.from_yaml text
          rescue ex
            Log.error { "CLIENT : Error parsing ClientPackage : #{ex.message}" }
            next
          end
          Log.info { "SERVER : #{pkg.messages.size} messages from client #{address} (#{pkg.saved} are already saved)" }

          new_messages = pkg.messages
            .select { |client_message| client_message.text.size > 0 }
            .map { |client_message| ServerMessage.new address, client_message }

          @@messages_file.print new_messages.to_yaml[4..]
          @@messages_file.flush
          @messages += new_messages

          ws.send ServerPackage.new(@messages[pkg.saved..]).to_yaml
        end
      end

      @server = HTTP::Server.new [@handler]
      @address = @server.bind_tcp @host, @port
      spawn @server.listen
    end

    def close
      @server.close
    end

    def self.wipe
      @@messages_file.close
      File.delete @@messages_path
    end
  end

  class Client
    @@messages_path : Path = Chyamlt.dir / "client.yml"
    @@messages_file = File.new @@messages_path, "a"
    @@input_path : Path = Chyamlt.dir / "input.yml"

    @size = 0

    def initialize(@host : String, @port : Int32)
      Dir.mkdir_p @@messages_path.parent
      Dir.mkdir_p @@input_path.parent
      File.each_line @@messages_path do |line|
        @size += 1 if line.starts_with? "- "
      end

      @address = URI.parse "wb://#{@host}:#{@port}"
      @socket = HTTP::WebSocket.new @address
      @socket.on_message do |text|
        Log.debug { "CLIENT : Parsing received messages" }
        pkg = begin
          ServerPackage.from_yaml text
        rescue ex
          Log.error { "CLIENT : Error parsing ServerPackage : #{ex.message}" }
          next
        end
        Log.info { "CLIENT : #{pkg.messages.size} messages from server #{@address}" }

        @size += pkg.messages.size
        @@messages_file.print pkg.messages.to_yaml[4..]
        @@messages_file.flush
        File.delete @@input_path
      end
      spawn @socket.run
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
            last_check = Time.utc
            sleep 0.2.seconds
            next
          end
          Log.debug { "CLIENT : Sending new messages" }
          @socket.send ClientPackage.new(@size, new_messages).to_yaml
          Log.debug { "CLIENT : Sent new messages" }
        end
        last_check = Time.utc
        sleep 0.2.seconds
      end
    end

    def close
      @socket.close
    end

    def self.wipe
      @@messages.close
      File.delete @@messages_path
      File.delete @@input_path
    end
  end
end

server = Chyamlt::Server.new "localhost", 3000
client = Chyamlt::Client.new "localhost", 3000
spawn client.monitor
sleep
