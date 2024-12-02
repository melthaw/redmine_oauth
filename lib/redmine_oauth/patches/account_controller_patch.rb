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

module RedmineOauth
  module Patches
    # AccountController patch
    module AccountControllerPatch
      ################################################################################################################
      # Overridden methods

      def login
        return super if request.post? || oauth_autologin_cookie.blank?

        redirect_to oauth_path(back_url: params[:back_url])
      end

      def logout
        delete_oauth_autologin_cookie
        return super if User.current.anonymous? || !request.post? || Setting.plugin_redmine_oauth[:oauth_logout].blank?

        site = Setting.plugin_redmine_oauth[:site]&.chomp('/')
        id = Setting.plugin_redmine_oauth[:client_id]
        tenant_id = Setting.plugin_redmine_oauth[:tenant_id]
        url = signout_url
        case Setting.plugin_redmine_oauth[:oauth_name]
        when 'Azure AD'
          logout_user
          redirect_to "#{site}/#{id}/oauth2/logout?post_logout_redirect_uri=#{url}"
        when 'Custom'
          logout_user
          redirect_to Setting.plugin_redmine_oauth[:custom_logout_endpoint]
        when 'GitLab', 'Google'
          Rails.logger.info "#{Setting.plugin_redmine_oauth[:oauth_name]} logout not implement"
          super
        when 'Keycloak'
          logout_user
          redirect_to "#{site}/realms/#{tenant_id}/protocol/openid-connect/logout?post_logout_redirect_uri=#{url}&client_id=#{id}"
        when 'Okta'
          logout_user
          redirect_to "#{site}/oauth2/v1/logout?id_token_hint=#{id}&post_logout_redirect_uri=#{url}"
        else
          super
        end
      rescue StandardError => e
        Rails.logger.error e.message
        flash['error'] = e.message
        redirect_to signin_path
      end

      ################################################################################################################
      # New methods

      private

      def delete_oauth_autologin_cookie
        cookies.delete :oauth_autologin
      end

      def oauth_autologin_cookie
        cookies[:oauth_autologin]
      end
    end
  end
end

AccountController.prepend RedmineOauth::Patches::AccountControllerPatch
