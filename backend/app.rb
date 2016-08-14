require 'rubygems'

require 'trans-api'
require 'oauth2'
require 'mysql2'
require 'open-uri'
require 'rss'
require 'json'
require 'sinatra/base'
require 'webrick'
require 'webrick/https'
require 'openssl'

set :public_folder, File.expand_path(File.dirname(__FILE__) + '/public')
set :sessions, true


def envRequire name
  unless ENV[name]
    raise "You must specify the #{name} env variable"
  end
  ENV[name]
end

OWNER_LEVEL = 3
EDITOR_LEVEL = 2
MEMBER_LEVEL = 1
VISITOR_LEVEL = 0
PERMISSIONS = {
  EDIT_USER:     3,
  READ_USER:     1,
  EDIT_FEED:     2,
  READ_FEED:     0,
  EDIT_LISTENER: 1,
  READ_LISTENER: 0,
  EDIT_TORRENT:  1,
  READ_TORRENT:  0,
}

# transmission client

TRANSMISSION_CONFIG = {
  host: 'transmission',
  path: '/transmission/',
  port: 9091,
  user: envRequire('TRANSMISSION_USER'),
  pass: envRequire('TRANSMISSION_PASS'),
}

puts "Setting up Transmission"
Trans::Api::Client.config = TRANSMISSION_CONFIG
Trans::Api::Torrent.default_fields = [ :id, :status, :name ]

# oauth2 client w/ google

G_API_CLIENT = envRequire('G_API_CLIENT')
G_API_SECRET = envRequire('G_API_SECRET')

puts "Setting up OAuth2 Client"
$oauth2Client = OAuth2::Client.new(G_API_CLIENT, G_API_SECRET, {
  :site          => 'https://accounts.google.com',
  :authorize_url => '/o/oauth2/auth',
  :token_url     => '/o/oauth2/token',
})

G_API_SCOPES = [
    'https://www.googleapis.com/auth/userinfo.email',
].join(' ')

# mysql client

puts "Setting up Mysql"
until $mysql
  begin
    $mysql = Mysql2::Client.new({
      :host     => 'mysql',
      :port     => 3306,
      :username => envRequire('MYSQL_USER'),
      :password => envRequire('MYSQL_PASSWORD'),
      :database => envRequire('MYSQL_DATABASE'),
    })
  rescue
    puts "Couldn't Connect, waiting 5 seconds..."
    sleep 5
  end
end

puts "Creating Tables"
$mysql.query("""
CREATE TABLE IF NOT EXISTS users (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  email VARCHAR(64) UNIQUE,
  name VARCHAR(48),
  level INT NOT NULL DEFAULT 0,
  last_online DATE,
  create_time DATE
);""")
$mysql.query("""
CREATE TABLE IF NOT EXISTS feeds (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  creator_id INT,
  uri VARCHAR(256),
  name VARCHAR(48) UNIQUE,
  update_duration INT,
  lastUpdate DATE
);""")
$mysql.query("""
CREATE TABLE IF NOT EXISTS listeners (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  feed_id INT NOT NULL,
  name VARCHAR(256),
  pattern VARCHAR(48) DEFAULT '.'
);""")
$mysql.query("""
CREATE TABLE IF NOT EXISTS user_listeners (
  user_id INT NOT NULL,
  feed_id INT NOT NULL,
  last_seen DATE
);""")

$firstUser = $mysql.query("SELECT COUNT(*) FROM users").first["COUNT(*)"] == 0
if $firstUser
  puts "First user to sign in will be made the owner."
end

def addUserToDb email, name, level
  begin
    puts "Adding #{email} to database with level #{level}"
    $mysql.query("INSERT INTO users (email, name, level, create_time) VALUES ('#{email}', '#{name}', #{level}, '#{Time.now.to_s.split(' ')[0..1]*' '}');")
    return $mysql.query("SELECT * FROM users WHERE email='#{email}';").first
  rescue Mysql2::Error => e
    puts "ERROR IN ADDING USER",$!.backtrace
    puts e.errno
    puts e.error
    return nil
  end
end

def updateUserStatus user_id
  begin
    $mysql.query("INSERT INTO users SET (last_online) VALUES ('#{Time.now.to_s.split(' ')[0..1]*' '}');")
  rescue Mysql2::Error => e
    puts "ERROR IN UPDATING USER STATUS",$!.backtrace
    puts e.errno
    puts e.error
  end
end

def hasPerm user_id, permission
  user = $mysql.query("SELECT * FROM users WHERE id='#{user_id}';").first
  return false unless user
  return PERMISSIONS[permission] <= user['level']
end

# sinatra

puts "Setting up Sinatra"

def redirect_uri
  uri = URI.parse(request.url)
  uri.path = '/oauth2callback'
  uri.query = nil
  uri.to_s
end

# ssl & config
unless File.exists?("cert.crt") && File.exists?("key.pem")
  raise "Please run ./setup to generate a SSL Cert"
end

certificate_content = File.open("cert.crt").read
key_content = File.open("key.pem").read 

server_options = {
  :Host => "0.0.0.0",
  :Port => "443",
  :SSLEnable => true,
  :SSLCertificate => OpenSSL::X509::Certificate.new(certificate_content),
  :SSLPrivateKey => OpenSSL::PKey::RSA.new(key_content)
}

class Server  < Sinatra::Base
  set :json_content_type, :json
  set :sessions, true

  get '/' do
    if session[:user_id]
      erb :index
    else
      erb :login
    end
  end

  get '/401' do 
    status 401
    {
      status: 401,
      message: "Not Authorized"
    }.to_json
  end

  # Api Routes

  get '/api/users' do
    user_id = session[:user_id]
    content_type :json
    if !hasPerm user_id, :READ_USER
      status 401
      {
        status: 401,
        message: "Not Authorized"
      }.to_json
    else
      status 200
      updateUserStatus user_id
      result = $mysql.query("SELECT * FROM users;")
      users = []
      result.each do |user|
        users << user
      end
      users.to_json
    end
  end

  get '/api/feeds' do
    user_id = session[:user_id]
    content_type :json
    if !hasPerm user_id, :READ_FEED
      status 401
      {
        status: 401,
        message: "Not Authorized"
      }.to_json
    else
      status 200
      updateUserStatus user_id
      result = $mysql.query("SELECT * FROM feeds;")
      feeds = []
      result.each do |feed|
        feeds << feed
      end
      feeds.to_json
    end
  end

  get '/api/listeners' do
    user_id = session[:user_id]
    content_type :json
    if !hasPerm user_id, :READ_LISTENER
      status 401
      {
        status: 401,
        message: "Not Authorized"
      }.to_json
    else
      status 200
      updateUserStatus user_id
      result = $mysql.query("SELECT * FROM listeners;")
      listeners = []
      result.each do |listener|
        listeners << listener
      end
      listeners.to_json
    end
  end

  get '/api/user/listeners' do
    user_id = session[:user_id]
    content_type :json
    if !hasPerm user_id, :READ_LISTENER
      status 401
      {
        status: 401,
        message: "Not Authorized"
      }.to_json
    else
      status 200
      updateUserStatus user_id
      result = $mysql.query("SELECT * FROM user_listeners WHERE user_id=#{user_id};")
      listeners = []
      result.each do |listener|
        listeners << listener
      end
      listeners.to_json
    end
  end

  get '/api/torrents' do
    user_id = session[:user_id]
    content_type :json
    if !hasPerm user_id, :READ_TORRENT
      status 401
      {
        status: 401,
        message: "Not Authorized"
      }.to_json
    else
      status 200
      updateUserStatus user_id
      torrents = []
      Trans::Api::Torrent.all.each do |torrent|
        torrents << {
          id: torrent.id,
          name: torrent.name,
          status: torrent.status,
          files: torrent.files.map{|f|{
              name: f.name,
              stat: f.stat,
            }
          },
        }
      end
      torrents.to_json
    end
  end

  post '/api/torrents/:id/:action' do
    user_id = session[:user_id]
    torrent = Trans::Api::Torrent.find(params[:id])
    content_type :json
    if !hasPerm user_id, :EDIT_TORRENT
      status 401
      {
        status: 401,
        message: "Not Authorized",
      }.to_json
    elsif !torrent
      status 404
      {
        status: 404,
        message: "Not Found",
      }.to_json
    else
      updateUserStatus user_id
      case params[:action]
      when "start"
        begin
          torrent.start!
          status 200,
          {
            status: 200,
            message: "OK",
          }.to_json
        rescue
          status 500,
          {
            status: 500,
            message: "Error",
            backtrace: $!.backtrace
          }.to_json
        end
      when "stop"
        begin
          torrent.stop!
          status 200,
          {
            status: 200,
            message: "OK",
          }.to_json
        rescue
          status 500,
          {
            status: 500,
            message: "Error",
            backtrace: $!.backtrace
          }.to_json
        end
      when "delete"
        begin
          torrent.delete!({delete_local_data: true})
          status 200,
          {
            status: 200,
            message: "OK",
          }.to_json
        rescue
          status 500,
          {
            status: 500,
            message: "Error",
            backtrace: $!.backtrace
          }.to_json
        end
      else
        status 404,
        {
          status: 404,
          message: "Operation '#{params[:action]}' Not Found",
        }.to_json
      end

    end
  end


  # Auth Routes

  get "/logout" do
    if session[:user_id]
      updateUserStatus session[:user_id]
      session.delete(:user_id)
    else
    redirect to('/')
  end

  get "/auth" do
    if session[:user_id]
      redirect to('/')
    else
      redirect $oauth2Client.auth_code.authorize_url(
        :redirect_uri => redirect_uri,
        :scope => G_API_SCOPES,
        :access_type => "offline",
      )
    end
  end

  get '/oauth2callback' do
    if session[:user_id]
      redirect to('/')
    end
    begin
      access_token = $oauth2Client.auth_code.get_token(params[:code], :redirect_uri => redirect_uri)
      data = access_token.get('https://www.googleapis.com/userinfo/email?alt=json').parsed
      isVerified = data['data']['isVerified']
      email = data['data']['email']

      if $firstUser
        user = addUserToDb(email, "Admin", OWNER_LEVEL)
        $firstUser = false
      end
      
      user = $mysql.query("SELECT * FROM users WHERE email='#{email}';").first 
      if user
        session[:user_id] = user['id']
        updateUserStatus user['id']
        redirect to('/')
      else
        redirect to('/401')
      end

      #session[:access_token] = access_token.token
      #session[:email] = email
    rescue 
      puts $!.backtrace
      redirect to('/')
    end
  end

end

Rack::Handler::WEBrick.run Server, server_options