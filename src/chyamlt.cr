require "yaml"
require "http/server"
require "http/web_socket"
require "uri"

module Chyamlt
  class Message
    include YAML::Serializable

    getter received : Time?
    getter sender : String?
    getter text : String

    def initialize(@sender, @text)
      @received = Time.utc
    end
  end

  class Server
    {% if flag?(:windows) %}
      @@path = Path.new("~", "AppData", "chyamlt", "server.yml").expand(home: true)
    {% else %}
      @@path = Path.new("~", ".config", "chyamlt", "server.yml").expand(home: true)
    {% end %}

    @messages : Array(Message)

    def initialize(@host : String, @port : Int32)
      Dir.mkdir_p @@path.parent
      @file = File.new @@path, "a"
      @messages = Array(Message).from_yaml File.new @@path rescue [] of Message
      @handler = HTTP::WebSocketHandler.new do |ws, ctx|
        Log.info { "SERVER : Connection from client #{ctx.request.remote_address}" }
        ws.on_message do |text|
          username = ctx.request.remote_address
          message = Message.new username.to_s, text
          Log.info { "SERVER : Message \"#{message}\" from client #{username}" }
          @file.print [message].to_yaml[4..]
          @file.flush
          @messages << message
          ws.send "ok"
        end
      end
      @server = HTTP::Server.new [@handler]
      @address = @server.bind_tcp @host, @port
      spawn @server.listen
    end
  end

  class Client
    {% if flag?(:windows) %}
      @@path = Path.new("~", "AppData", "chyamlt", "client.yml").expand(home: true)
    {% else %}
      @@path = Path.new("~", ".config", "chyamlt", "client.yml").expand(home: true)
    {% end %}

    @messages : Array(Message)

    @i = 0
    @buf = [] of String

    def initialize(@host : String, @port : Int32)
      Dir.mkdir_p @@path.parent
      @messages = Array(Message).from_yaml File.new @@path rescue [] of Message

      @uri = URI.parse "wb://#{@host}:#{@port}"
      @socket = HTTP::WebSocket.new @uri
      @socket.on_message do |message|
        Log.info { "CLIENT : Message \"#{message}\" from server #{@uri}" }
      end
      spawn @socket.run
    end

    def send(message : String)
      @socket.send message
    end

    protected def process_buf
      message = Message.from_yaml @buf.join
      @buf.clear
      if @i < @messages.size
        raise "corrupted" if message != @messages[@i]
      else
        send message.text
      end
    end

    def monitor
      last_check : Time? = nil
      loop do
        this_check = Time.utc
        if !last_check || File.info(@@path).modification_time > last_check
          @i = 0
          File.each_line @@path do |line|
            if @i > 0
              process_buf if @buf.size > 0 && line.starts_with? "- "
              @buf << line[2..]
            end
            @i += 1
          end
          process_buf
        end
        last_check = this_check
        sleep 0.2.seconds
      end
    end
  end
end

server = Chyamlt::Server.new "localhost", 3000
client = Chyamlt::Client.new "localhost", 3000
spawn client.monitor
sleep
