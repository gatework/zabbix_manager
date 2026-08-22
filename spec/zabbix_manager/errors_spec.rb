# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ZabbixManager exceptions" do
  it "使用轻量命名异常区分输入、API、冲突和传输错误" do
    expect(ZabbixManager::Invalid.new).to be_a(ArgumentError)
    expect(ZabbixManager::ApiError.new).to be_a(StandardError)
    expect(ZabbixManager::Conflict.new).to be_a(ZabbixManager::ApiError)
    expect(ZabbixManager::TransportError.new).to be_a(StandardError)
  end
end
