# frozen_string_literal: true

require "spec_helper"

describe "ZabbixManager::Screens" do
  let(:screens_mock) { ZabbixManager::Screens.new(client) }
  let(:client) { double }

  describe ".method_name" do
    subject { screens_mock.method_name }

    it { is_expected.to eq "screen" }
  end

  describe ".identify" do
    subject { screens_mock.identify }

    it { is_expected.to eq "name" }
  end

  describe ".get_or_create_for_host" do
    subject { screens_mock.get_or_create_for_host(data) }

    let(:data) { { screen_name: screen_name, graphids: graphids } }
    let(:screen_name) { "testscreen" }
    let(:result) { { "screenids" => ["1"] } }
    let(:graphids) { [2222] }
    let(:method_name) { "testmethod" }
    let(:existing_screen_id) { 1212 }
    let(:newly_created_screen_id) { 3434 }

    before do
      allow(screens_mock).to receive(:get_id).with(name: screen_name).and_return(existing_screen_id)
    end

    context "when screen already exist" do
      it "returns the id of first screen" do
        expect(subject).to eq existing_screen_id
      end
    end

    context "when screen doesn't exist" do
      let(:existing_screen_id) { nil }
      let(:screenitems) do
        graphids.each_with_index.map do |graphid, index|
          {
            resourcetype: 0,
            resourceid: graphid,
            x: (index % hsize).to_i,
            y: index / hsize,
            valign: valign,
            halign: halign,
            rowspan: rowspan,
            colspan: colspan,
            height: height,
            width: width
          }
        end
      end

      before do
        allow(screens_mock).to receive(:create).with(
          name: screen_name,
          hsize: hsize,
          vsize: vsize,
          screenitems: screenitems
        ).and_return(newly_created_screen_id)
      end

      context "when data do not have all value for request" do
        let(:hsize) { 3 }
        let(:valign) { 2 }
        let(:halign) { 2 }
        let(:rowspan) { 1 }
        let(:colspan) { 1 }
        let(:height) { 320 }
        let(:width) { 200 }
        let(:vsize) { graphids.length.fdiv(hsize).ceil }

        it "creates screen with default and rest of provided values" do
          expect(subject).to eq newly_created_screen_id
        end
      end

      context "when the final row is only partially filled" do
        let(:graphids) { [1, 2, 3, 4] }
        let(:hsize) { 3 }
        let(:valign) { 2 }
        let(:halign) { 2 }
        let(:rowspan) { 1 }
        let(:colspan) { 1 }
        let(:height) { 320 }
        let(:width) { 200 }
        let(:vsize) { 2 }

        it "rounds vsize up and places the final graph on the next row" do
          expect(subject).to eq newly_created_screen_id
          expect(screens_mock).to have_received(:create).with(
            hash_including(vsize: 2, screenitems: include(hash_including(resourceid: 4, x: 0, y: 1)))
          )
        end
      end

      context "when data do not have all value for request" do
        let(:hsize) { 3 }
        let(:valign) { 2 }
        let(:halign) { 2 }
        let(:rowspan) { 1 }
        let(:colspan) { 1 }
        let(:height) { 320 }
        let(:width) { 200 }
        let(:vsize) { 5 }

        let(:data) do
          {
            screen_name: screen_name,
            graphids: graphids,
            hsize: hsize,
            valign: valign,
            halign: halign,
            rowspan: rowspan,
            colspan: colspan,
            height: height,
            width: width,
            vsize: vsize
          }
        end

        it "creates screen with values provided in data" do
          expect(subject).to eq newly_created_screen_id
        end
      end
    end
  end
end
