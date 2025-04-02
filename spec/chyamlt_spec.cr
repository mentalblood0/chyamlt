require "openssl/hmac"
require "./spec_helper"

describe Chyamlt::Server do
  Spec.before_each do
    Chyamlt::Server.wipe
  end
  Spec.after_each do
    Chyamlt::Server.wipe
  end
  it "not vulnerable to size attacks" do
    server = Chyamlt::Server.new
    client = HTTP::Client.new URI.parse "http://localhost:3000"
    size = 9 * 1024
    big_message = Chyamlt::ClientMessage.new "a" * size
    response = client.post "/", body: Chyamlt::ClientPackage.new(0, [big_message]).to_yaml
    server.close
    File.new(Chyamlt::Server.messages_path).size.should be < size
  end
  it "can use cryptography" do
    OpenSSL::HMAC.hexdigest(OpenSSL::Algorithm::SHA256, "key", "data")
  end
end
