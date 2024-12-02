# frozen_string_literal: true

# Redmine plugin OAuth
#
# Karel Pičman <karel.picman@kontron.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require 'account_controller'
require 'jwt'

# OAuth controller
class RedmineOauthController < AccountController
  before_action :verify_csrf_token, only: [:oauth_callback]

  def oauth
    session[:back_url] = params[:back_url]
    session[:autologin] = params[:autologin]
    session[:oauth_autologin] = params[:oauth_autologin]
    oauth_csrf_token = generate_csrf_token
    session[:oauth_csrf_token] = oauth_csrf_token
    case Setting.plugin_redmine_oauth[:oauth_name]
    when 'Azure AD'
      redirect_to oauth_client.auth_code.authorize_url(
        redirect_uri: oauth_callback_url,
        state: oauth_csrf_token,
        scope: 'user:email'
      )
    when 'GitLab'
      redirect_to oauth_client.auth_code.authorize_url(
        redirect_uri: oauth_callback_url,
        state: oauth_csrf_token,
        scope: 'read_user'
      )
    when 'Google'
      redirect_to oauth_client.auth_code.authorize_url(
        redirect_uri: oauth_callback_url,
        state: oauth_csrf_token,
        scope: 'profile email'
      )
    when 'Keycloak'
      redirect_to oauth_client.auth_code.authorize_url(
        redirect_uri: oauth_callback_url,
        state: oauth_csrf_token,
        scope: 'openid email'
      )
    when 'Okta'
      redirect_to oauth_client.auth_code.authorize_url(
        redirect_uri: oauth_callback_url,
        state: oauth_csrf_token,
        scope: 'openid profile email'
      )
    when 'Custom'
      redirect_to oauth_client.auth_code.authorize_url(
        redirect_uri: oauth_callback_url,
        state: oauth_csrf_token,
        scope: Setting.plugin_redmine_oauth[:custom_scope]
      )
    else
      flash['error'] = l(:oauth_invalid_provider)
      redirect_to signin_path
    end
  rescue StandardError => e
    Rails.logger.error e.message
    flash['error'] = e.message
    redirect_to signin_path
  end

  def oauth_callback
    raise StandardError, l(:notice_access_denied) if params['error']

    case Setting.plugin_redmine_oauth[:oauth_name]
    when 'Azure AD'
      token = oauth_client.auth_code.get_token(params['code'], redirect_uri: oauth_callback_url)
      user_info = JWT.decode(token.token, nil, false).first
      email = user_info['unique_name']
    when 'GitLab'
      token = oauth_client.auth_code.get_token(params['code'], redirect_uri: oauth_callback_url)
      userinfo_response = token.get('/api/v4/user', headers: { 'Accept' => 'application/json' })
      user_info = JSON.parse(userinfo_response.body)
      user_info['login'] = user_info['username']
      email = user_info['email']
    when 'Google'
      token = oauth_client.auth_code.get_token(params['code'], redirect_uri: oauth_callback_url)
      userinfo_response = token.get('https://openidconnect.googleapis.com/v1/userinfo',
                                    headers: { 'Accept' => 'application/json' })
      user_info = JSON.parse(userinfo_response.body)
      user_info['login'] = user_info['email']
      email = user_info['email']
    when 'Keycloak'
      token = oauth_client.auth_code.get_token(params['code'], redirect_uri: oauth_callback_url)
      user_info = JWT.decode(token.token, nil, false).first
      user_info['login'] = user_info['preferred_username']
      email = user_info['email']
    when 'Okta'
      token = oauth_client.auth_code.get_token(params['code'], redirect_uri: oauth_callback_url)
      userinfo_response = token.get(
        "/oauth2/#{Setting.plugin_redmine_oauth[:tenant_id]}/v1/userinfo",
        headers: { 'Accept' => 'application/json' }
      )
      user_info = JSON.parse(userinfo_response.body)
      user_info['login'] = user_info['preferred_username']
      email = user_info['email']
    when 'Custom'
      token = oauth_client.auth_code.get_token(params['code'], redirect_uri: oauth_callback_url)
      if Setting.plugin_redmine_oauth[:custom_profile_endpoint].strip.empty?
        user_info = JWT.decode(token.token, nil, false).first
      else
        userinfo_response = token.get(
          Setting.plugin_redmine_oauth[:custom_profile_endpoint],
          headers: { 'Accept' => 'application/json' }
        )
        user_info = JSON.parse(userinfo_response.body)
      end
      user_info['login'] = user_info[Setting.plugin_redmine_oauth[:custom_uid_field]]
      email = user_info[Setting.plugin_redmine_oauth[:custom_email_field]]
    else
      raise StandardError, l(:oauth_invalid_provider)
    end
    raise StandardError, l(:oauth_no_verified_email) unless email

    # Roles
    keys = Setting.plugin_redmine_oauth[:validate_user_roles]&.split('.')
    if keys&.size&.positive?
      roles = user_info
      while keys.size.positive?
        key = keys.shift
        unless roles.key?(key)
          roles = []
          break
        end
        roles = roles[key]
      end
      roles = roles.to_a
      @admin = roles.include?('admin')
      if roles.blank? || (roles.exclude?('user') && !@admin)
        Rails.logger.info 'Authentication failed due to a missing role in the token'
        params[:username] = email
        invalid_credentials
        raise StandardError, l(:notice_account_invalid_credentials)
      end
    end

    # Try to log in
    set_params
    try_to_login email, user_info
  rescue StandardError => e
    Rails.logger.error e.message
    flash['error'] = e.message
    redirect_to signin_path
  end

  def set_oauth_autologin_cookie(value, request)
    cookie_options = {
      value: value,
      expires: 1.year.from_now,
      path: RedmineApp::Application.config.relative_url_root || '/',
      same_site: :lax,
      secure: request.ssl?,
      httponly: true
    }
    cookies[:oauth_autologin] = cookie_options
  end

  private

  def set_params
    params['back_url'] = session[:back_url]
    session.delete :back_url
    params['autologin'] = session[:autologin]
    session.delete :autologin
    params['oauth_autologin'] = session[:oauth_autologin]
    session.delete :oauth_autologin
  end


  # Override : Automatically register a user
  def register_automatically(user, project, role, &block)
    # Automatic activation
    user.activate
    user.last_login_on = Time.now
    if user.save
      unless project.nil?
        member = Member.new(project: project, user: user)
        unless role.nil?
          member.roles << role
        end
        member.save
      end

      self.logged_user = user
      flash[:notice] = l(:notice_account_activated)
      redirect_to my_account_path
    else
      yield if block
    end
  end

  def try_to_login(email, info)
    user = User.joins(:email_addresses).where(email_addresses: { address: email }).first
    if user # Existing user
      if user.registered? # Registered
        account_pending user
      elsif user.active? # Active
        handle_active_user user
        user.update_last_login_on!
        if Setting.plugin_redmine_oauth[:update_login] && (info['login'] || info['unique_name'])
          user.login = info['login'] || info['unique_name']
          Rails.logger.error(user.errors.full_messages.to_sentence) unless user.save
        end
        # Disable 2FA initialization request
        session.delete(:must_activate_twofa)
        # Disable password change request
        session.delete(:pwd)
      else # Locked
        handle_inactive_user user
      end
    elsif Setting.plugin_redmine_oauth[:self_registration] && Setting.plugin_redmine_oauth[:self_registration] != '0'
      # Create on the fly
      user = User.new
      user.mail = email
      firstname, lastname = info['name'].split if info['name'].present?
      key = Setting.plugin_redmine_oauth[:custom_firstname_field]
      key ||= 'given_name'
      firstname ||= info[key]
      user.firstname = firstname
      key = Setting.plugin_redmine_oauth[:custom_lastname_field]
      key ||= 'family_name'
      lastname ||= info[key]
      user.lastname = lastname
      user.mail = email
      login = info['login']
      login ||= info['unique_name']
      user.login = login
      user.random_password
      user.register

      case Setting.plugin_redmine_oauth[:self_registration]
      when '1'
        register_by_email_activation(user) do
          onthefly_creation_failed user
        end
      when '3'
        # add to project
        project = nil
        if !Setting.plugin_redmine_oauth[:auto_assign_projects].nil? and !Setting.plugin_redmine_oauth[:auto_assign_projects].blank?
          project = Project.find(Setting.plugin_redmine_oauth[:auto_assign_projects])
        end

        role = nil
        if !Setting.plugin_redmine_oauth[:auto_assign_projects].nil? and !Setting.plugin_redmine_oauth[:auto_assign_projects].blank?
          role = Role.find(Setting.plugin_redmine_oauth[:auto_assign_roles])
        end

        register_automatically(user, project, role) do
          onthefly_creation_failed user
        end
      else
        register_manually_by_administrator(user) do
          onthefly_creation_failed user
        end
      end
    else  # Invalid credentials
      params[:username] = email
      invalid_credentials
      raise StandardError, l(:notice_account_invalid_credentials)
    end
    return if @admin.nil?

    user.admin = @admin
    Rails.logger.error(user.errors.full_messages.to_sentence) unless user.save
  end

  def oauth_client
    return @client if @client

    site = Setting.plugin_redmine_oauth[:site]&.chomp('/')
    raise StandardError, l(:oauth_invalid_provider) unless site

    @client =
      case Setting.plugin_redmine_oauth[:oauth_name]
      when 'Azure AD'
        OAuth2::Client.new(
          Setting.plugin_redmine_oauth[:client_id],
          Redmine::Ciphering.decrypt_text(Setting.plugin_redmine_oauth[:client_secret]),
          site: site,
          authorize_url: "/#{Setting.plugin_redmine_oauth[:tenant_id]}/oauth2/authorize",
          token_url: "/#{Setting.plugin_redmine_oauth[:tenant_id]}/oauth2/token"
        )
      when 'GitLab'
        OAuth2::Client.new(
          Setting.plugin_redmine_oauth[:client_id],
          Redmine::Ciphering.decrypt_text(Setting.plugin_redmine_oauth[:client_secret]),
          site: site,
          authorize_url: '/oauth/authorize',
          token_url: '/oauth/token'
        )
      when 'Google'
        OAuth2::Client.new(
          Setting.plugin_redmine_oauth[:client_id],
          Redmine::Ciphering.decrypt_text(Setting.plugin_redmine_oauth[:client_secret]),
          site: site,
          authorize_url: '/o/oauth2/v2/auth',
          token_url: 'https://oauth2.googleapis.com/token'
        )
      when 'Keycloak'
        OAuth2::Client.new(
          Setting.plugin_redmine_oauth[:client_id],
          Redmine::Ciphering.decrypt_text(Setting.plugin_redmine_oauth[:client_secret]),
          site: site,
          authorize_url: "/realms/#{Setting.plugin_redmine_oauth[:tenant_id]}/protocol/openid-connect/auth",
          token_url: "/realms/#{Setting.plugin_redmine_oauth[:tenant_id]}/protocol/openid-connect/token"
        )
      when 'Okta'
        OAuth2::Client.new(
          Setting.plugin_redmine_oauth[:client_id],
          Redmine::Ciphering.decrypt_text(Setting.plugin_redmine_oauth[:client_secret]),
          site: site,
          authorize_url: "/oauth2/#{Setting.plugin_redmine_oauth[:tenant_id]}/v1/authorize",
          token_url: "/oauth2/#{Setting.plugin_redmine_oauth[:tenant_id]}/v1/token"
        )
      when 'Custom'
        OAuth2::Client.new(
          Setting.plugin_redmine_oauth[:client_id],
          Redmine::Ciphering.decrypt_text(Setting.plugin_redmine_oauth[:client_secret]),
          site: site,
          authorize_url: Setting.plugin_redmine_oauth[:custom_auth_endpoint],
          token_url: Setting.plugin_redmine_oauth[:custom_token_endpoint]
        )
      else
        raise StandardError, l(:oauth_invalid_provider)
      end
  end

  def verify_csrf_token
    if params[:state].blank? || (params[:state] != session[:oauth_csrf_token])
      render_error status: 422, message: l(:error_invalid_authenticity_token)
    end
    session.delete :oauth_csrf_token
  end
end
