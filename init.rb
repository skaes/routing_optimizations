# load monkey patches to rails routing code according to version
# log a warning if the rails version is not supported

case Rails.version
when /^2\.1/
  require "routing_monkey_patches_rails_2_1"
when /^2\.2/
  require "routing_monkey_patches_rails_2_2"
else
  ActionController::Base.logger.warn "Rails version not compatible with lazy routing"
end
