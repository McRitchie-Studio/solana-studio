# frozen_string_literal: true

Rails.application.routes.draw do
  get "/lab/guard",  to: "e2e_lab#guard"
  get "/lab/modal",  to: "e2e_lab#modal"
  get "/lab/phantom_deeplink", to: "e2e_lab#phantom_deeplink"
end
