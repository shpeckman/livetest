require "./spec_helper"

describe Livetest::Keymap do
  us = Livetest::Keymap.new("us", nil, "pc105", nil)
  be = Livetest::Keymap.new("be", "oss", "pc105", nil)
  shift = 42_u16

  it "maps characters to evdev keys and modifiers" do
    us.char('a').should eq(Livetest::Keymap::Stroke.new(30, [] of UInt16))
    us.char('A').should eq(Livetest::Keymap::Stroke.new(30, [shift]))
    us.char('\n').should eq(Livetest::Keymap::Stroke.new(28, [] of UInt16))
    us.named("F5").should eq(Livetest::Keymap::Stroke.new(63, [] of UInt16))
    us.char('€').should be_nil
  end

  it "follows the layout" do
    be.char('a').try(&.code).should eq(16)
    be.char('é').should eq(Livetest::Keymap::Stroke.new(3, [] of UInt16))
    be.char('1').should eq(Livetest::Keymap::Stroke.new(2, [shift]))
    be.char('@').try(&.modifiers.size).should eq(1)
    be.modifier("shift").should eq(shift)
    be.modifier("altgr").should_not be_nil
  end
end
