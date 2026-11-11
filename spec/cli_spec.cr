require "./spec_helper"

describe Livetest do
  it "fails on a missing cases file" do
    Livetest.run(["-c", "/nonexistent/cases.yml"], TestTerminal.new).should eq(2)
  end
end
