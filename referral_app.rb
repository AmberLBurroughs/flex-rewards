require 'csv'
require 'faraday'
require 'json'
require 'pry'
require 'sinatra'
require 'sinatra/base'
require 'sinatra/activerecord'
require 'sinatra/cross_origin'
require 'time'

require './config/environments' #database configuration
require './models/employee_discount'
require './models/employee_invitation'
require './models/discount'
require './models/invitation'

API_KEY = ''
PASSWORD = ''
SHOP_NAME = 'the-flex-company'
# SharedSecret
BASE_URL = "https://#{API_KEY}:#{PASSWORD}@#{SHOP_NAME}.myshopify.com"

register Sinatra::CrossOrigin

# check for unupdated users and attempt to update them
Thread.new do
  while true do
    sleep 15
    # desync_failed_invites()
    sync_klaviyo_data(employee_invites=false)
    sync_klaviyo_data(employee_invites=true)
  end
end

get '/' do
  redirect 'https://flexfits.com/'
end

# given a customer ID, get the number of available invies
get '/customer' do
  cross_origin :allow_origin => 'https://flexfits.com'
  content_type :json

  customer_email = request['customer_email']
  customer_id = request['customer_id']

  valid_user = verify_user(customer_id, customer_email)

  if params.length === 0 || !valid_user
    redirect 'https://flexfits.com/'
  end

  if customer_email.length > 13 && (customer_email[-13..-1] == "@flexfits.com" || customer_email == "jazmineduke@hotmail.com")
    { count: 99 }.to_json
  else
    total_count = invite_count(customer_id)
    { count: total_count }.to_json
  end

end

get '/invited' do
  cross_origin :allow_origin => 'https://flexfits.com'
  content_type :json

  customer_email = request['customer_email']
  customer_id = request['customer_id']
  if params.length === 0 || params.length != 2
    redirect 'https://flexfits.com/'
  end

  valid_user = verify_user(customer_id, customer_email)
  if !valid_user
    redirect 'https://flexfits.com'
  end

  if customer_email.length > 13 && (customer_email[-13..-1] == "@flexfits.com" || customer_email == "jazmineduke@hotmail.com")
    invites = EmployeeInvitation.where(invited_by: customer_id)
    invites.to_json
  else
    invites = Invitation.where(invited_by: customer_id)
    invites.to_json
  end
end

# given a customer ID, customer email and new user email
# invite the new user via Swell API
post '/invite' do
  cross_origin :allow_origin => 'https://flexfits.com'
  content_type :json
  customer_email = request['customer_email']
  customer_id = request['customer_id']
  new_user = request['new_user']
  new_name = request['new_name']

  valid_user = verify_user(customer_id, customer_email)
  if !valid_user
    redirect 'https://flexfits.com'
  end

  total_count = invite_count(customer_id)
  invitable = unregistered_user(new_user)
  valid_email = new_user =~ /\A([\w+\-].?)+@[a-z\d\-]+(\.[a-z]+)*\.[a-z]+\z/i # regex for email validation


  if invitable && customer_email.length > 13 && (customer_email[-13..-1] == "@flexfits.com" || customer_email == "jazmineduke@hotmail.com")
    employee_invite(customer_id, new_user, new_name)
    return { success: true }.to_json
  elsif invitable && total_count > 0 && valid_email
    invite_user(customer_id, new_user, new_name)
    return { success: true }.to_json
  elsif total_count <= 0
    return { success: false, error: 'no_invites' }.to_json
  elsif !invitable
    return { success: false, error: 'user_exists' }.to_json
  elsif !valid_email || valid_email.nil?
    return { success: false, error: 'invalid_email' }.to_json
  end
end

post '/discount_code' do
  cross_origin :allow_origin => 'https://flexfits.com'
  content_type :json

  # put a delay to ensure user shows up in klayviyo
  sleep 3

  customer_email = request['customer_email']
  customer_id = request['customer_id']
  new_user = request['new_user']
  first_name = request['new_first_name']
  last_name = request['new_last_name']

  valid_user = verify_user(customer_id, customer_email)
  valid_email = new_user =~ /\A([\w+\-].?)+@[a-z\d\-]+(\.[a-z]+)*\.[a-z]+\z/i # regex for email validation
  if !valid_user
    redirect 'https://flexfits.com'
  elsif !valid_email || valid_email.nil?
    return { success: false, error: 'invalid_email' }.to_json
  end

  if customer_email.length > 13 && customer_email[-13..-1] == "@flexfits.com" || customer_email == "jazmineduke@hotmail.com"
    code = get_unused_employee_discount()
    update_discount_code(new_user, first_name, last_name, discount=code)
    return { success: true }.to_json
  else
    code = get_unused_discount()
    update_discount_code(new_user, first_name, last_name, discount=code)
    return { success: true }.to_json
  end
end

post '/refresh_discount_codes' do
  password = request['password']
  if password != 'AMBERflex__20161234'
    return { success: false }.to_json
  end
  CSV.foreach('discounts/discount_codes.csv') do |row|
    code = row[0]
    new_discount_code(code)
  end
  return { success: true }.to_json
end

post '/refresh_employee_codes' do
  password = request['password']
  if password != 'AMBERflex__20161234'
    return { success: false }.to_json
  end
  CSV.foreach('discounts/employee_discount_codes.csv') do |row|
    code = row[0]
    new_employee_code(code)
  end
  return { success: true }.to_json
end

# create new faraday connection
def http_connection
  Faraday.new(url: BASE_URL, ssl: { verify: false }) do |faraday|
    faraday.request  :url_encoded             # form-encode POST params
    faraday.adapter  Faraday.default_adapter  # make requests with Net::https
  end
end

def klaviyo_connection
  Faraday.new(url: 'https://a.klaviyo.com/api/v1', ssl: { verify: false }) do |faraday|
    faraday.request  :url_encoded             # form-encode POST params
    faraday.adapter  Faraday.default_adapter  # make requests with Net::https
  end
end

# check if the customers tags include Active Subscriber
def is_active_subscriber(customer_id)
  conn = http_connection()
  is_active = false
  response = conn.get do |req|
    req.url "/admin/customers/#{customer_id}.json"
  end
  customer = JSON.parse(response.body)['customer']
  if customer['tags'].include?('Active Subscriber')
   is_active = true
  end
  return is_active
end

def invite_count(customer_id)
  if is_active_subscriber(customer_id) != true
    return 0
  end
  orders = order_count(customer_id)
  invites = used_invites(customer_id)
  total_count = orders - invites

  # total_count should never be greater than 5, or less than 0.
  total_count = total_count < 0 ? 0 : total_count
  total_count = total_count > 5 ? 5 : total_count
end


# get total number of orders that have the
# word 'subscription' in at least one line item
def order_count(customer_id)
  conn = http_connection()

  response = conn.get do |req|
    req.url '/admin/orders.json'
    req.params = {customer_id: customer_id, limit: 250, status: 'any', fulfillment_status: 'fulfilled'}
  end

  orders = JSON.parse(response.body)['orders']
  get_retroactive_subcount(orders)
end

# get order count of 24 pack subs and 8 pack subs
def sub_order_count(order_count, order)
  running_count = 0
  sub_24pack = [
     '24 Pack Free Trial - (In Person #1)', 'FLEX - 24 Pack Monthly Subscription',
     'FLEX - 24 Pack Quarterly Subscription', 'FLEX - 24 Pack Subscription',
     'FLEX - 24 Pack Subscription (Ships every 3 Months)'
     ]
  sub_8pack = [
    '8 Pack Free Trial - (In Person #1)', '8 Pack Free Trial - I Hate Tampons',
    '8 Pack Free Trial - Nasty Woman', '8 Pack Free Trial - Nasty Woman',
    '8 Pack Free Trial - Sierra', 'FLEX - 8 Pack Gift',
    'FLEX - 8 Pack Subscription', 'FLEX - 8 Pack Subscription (First Month Free)',
    'FLEX - 8 Pack Trial (Risk Free)', 'FLEX - Friends & Family 8 Pack Subscription (First Month Free)',
    'FLEX - Referral 8 Pack Subscription (First Month Free)'
    ]


    line_items = order['line_items']
    line_items.each do |li|
      if sub_24pack.include?(li['title']) && order_count == 0
        return 2
      elsif sub_8pack.include?(li['title'])  && order_count == 0 && running_count != 2
        running_count = 1

      elsif order_count > 0 && (sub_24pack.include?(li['title']) || sub_8pack.include?(li['title']))
        return 1
      end
    end
    return running_count
end



# get total of number of orders that count.
# Note that we will only count a MAXIMUM of three orders
# placed before April 1, 2017. This means a person who has
# 6 orders will only get 2 points (for three orders counted)
def get_retroactive_subcount(orders)
  sorted_orders = orders.sort{ |order| Time.parse(order['created_at']).to_i  }
  retroactive_cutoff = Time.parse('2017-04-01T00:00:00-00:00').to_i

  order_count = 0

  sorted_orders.each do |order|
    next if !order['confirmed'] || order['financial_status'] != 'paid'
    order_time = Time.parse(order['created_at']).to_i
    if order_time < retroactive_cutoff && order_count < 3
      order_count += sub_order_count(order_count, order)
    elsif order_time >= retroactive_cutoff
      order_count += sub_order_count(order_count, order)
    end
  end

  # should be at least three orders, for a user
  # to get invites.
  invites = 0
  if order_count >= 2
    invites = order_count
  end
  return invites
end


# logic that checks all line items for a given customer.
# should only count a single order once, even if there are
# multiple subscription items in it.
def get_subcount(orders)
  running_count = -2

  orders.each do |order|
    next if !order['confirmed'] || order['financial_status'] != 'paid'
    line_items = order['line_items']
    line_items.each do |li|
      if li['title'].include?('Subscription') || li['title'].include?('subscription') ||  li['title'].include?('trial') ||  li['title'].include?('Trial')
        running_count += 1
        break
      end
    end
  end

  running_count
end

# hacky security goes here: for a given customer ID
# and user email, check that the email is actually associated
# with this customer ID.
# (only the user should know this!)
def verify_user(customer_id, email)
  conn = http_connection()

  response = conn.get do |req|
    req.url "/admin/customers/#{customer_id}.json"
  end
  customer = JSON.parse(response.body)['customer']
  customer['email'] == email
end

# verify that the person being invited does not already
# exist as a flex user.
def unregistered_user(new_user)
  conn = http_connection()

  response = conn.get do |req|
    req.url "/admin/customers/search.json"
    req.params = { query: new_user}
  end
  customers = JSON.parse(response.body)['customers']
  customers.length == 0 && Invitation.where(email: new_user).length == 0
end

### DATABASE LOGIC GOES HERE ###

def used_invites(customer_id)
  invited = Invitation.where(invited_by: customer_id).length
  return invited
end

def employee_invite(customer_id, new_user, new_name)
  invitation = EmployeeInvitation.new
  invitation.invited_by = customer_id
  invitation.email = new_user.downcase
  invitation.name = new_name
  invitation.save!

  split_name = new_name.split(" ")
  conn = klaviyo_connection
  response = conn.post do |req|
    req.url "/person"
    req.params = { 'api_key': '', '$email': new_user.downcase, '$first_name': new_name[0], '$last_name': new_name[1]}
  end
end

def invite_user(customer_id, new_user, new_name)
  invitation = Invitation.new
  invitation.invited_by = customer_id
  invitation.email = new_user.downcase
  invitation.name = new_name
  invitation.save!

  split_name = new_name.split(" ")
  conn = klaviyo_connection
  response = conn.post do |req|
    req.url "/person"
    req.params = { 'api_key': '', '$email': new_user.downcase, '$first_name': new_name[0], '$last_name': new_name[1]}
  end
end

def get_klaviyo_profile(email)
  conn = klaviyo_connection()
  response = conn.get do |req|
    req.url '/api/v1/segment/JGntbE/members'
    req.params = { 'api_key': '', 'email': email.downcase}
  end

  emails = JSON.parse(response.body)

  emails['data'].each do |email_data|
    if email_data['email'] == email
      return email_data
    end
  end

  print "Error: Failed to find user '#{email}' in Klaviyo profiles."
  return nil
end

def get_unused_employee_discount()
  return EmployeeDiscount.where(email: nil).first
end

def get_unused_discount()
  return Discount.where(email: nil).first
end

def update_discount_code(email, first_name, last_name, discount=nil)
  discount.email = email.downcase
  discount.first_name = first_name
  discount.last_name = last_name
  discount.klaviyo_synced = false
  discount.save!
end

def update_klaviyo_profile(klaviyo_profile, discount=nil)
  profile_id = klaviyo_profile['person']['id']
  conn = klaviyo_connection()
  response = conn.put do |req|
    req.url "/api/v1/person/#{profile_id}"
    req.params = { 'api_key': '', '$first_name': discount.first_name,
      '$last_name': discount.last_name, 'discount_code': discount.code}
  end

  if response.status == 200
    discount.klaviyo_synced = true
    discount.save!
    return true
  else
    puts "FAILED Klaviyo update: #{JSON.parse(response.body)}"
    return false
  end

  #JSON.parse(response.body)
  return false
end

def new_discount_code(code)
  discount = Discount.new
  discount.code = code
  discount.email = nil
  discount.klaviyo_synced = false
  discount.save!
end

def new_employee_code(code)
  discount = EmployeeDiscount.new
  discount.code = code
  discount.email = nil
  discount.klaviyo_synced = false
  discount.save!
end

def desync_failed_invites()
  #invitations = Invitation.length
end

def sync_klaviyo_data(employee_invites=false)
  if employee_invites
    discounts = changed_employee_invites()
    log_text = "employee invited"
  else
    discounts = changed_klaviyo_users()
    log_text = "regular"
  end

  updated_users = 0

  if discounts.length === 0
    puts "No #{log_text} users need updating. Checking again in 15..."
  else
    puts "Attempting to update #{discounts.length} #{log_text} profiles in Klaviyo..."
    discounts.each do |discount|
      puts "Looking up profile for #{discount.email}"
      klaviyo_profile = get_klaviyo_profile(discount.email)
      if klaviyo_profile.nil?
        puts "No profile found for #{discount.email}"
        next
      end
      update_klaviyo_profile(klaviyo_profile, discount=discount)
      puts "Updated profile for #{discount.email}"
      updated_users += 1
    end
    puts "Updated #{updated_users} profiles in Klaviyo. Bye!"
  end
end

def changed_klaviyo_users()
  needs_update = Discount.all.where('discounts.email IS NOT null').where('discounts.klaviyo_synced = ?', false)
  needs_update
end

def changed_employee_invites()
  needs_update = EmployeeDiscount.all.where('employee_discounts.email IS NOT null').where('employee_discounts.klaviyo_synced = ?', false)
  needs_update
end
