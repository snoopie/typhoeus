require File.expand_path(File.dirname(__FILE__) + '/../spec_helper')

# some of these tests assume that you have some local services running.
# ruby spec/servers/app.rb -p 3000
# ruby spec/servers/app.rb -p 3001
# ruby spec/servers/app.rb -p 3002

# FIXME: why does the test server hang on PUTs?
# def all_methods;       [:get, :head, :post, :put, :delete]; end
def all_methods;       [:get, :head, :post, :delete]; end
def retryable_methods; [:get]; end
def oneshot_methods;   all_methods - retryable_methods; end

describe Typhoeus::Hydra do
  describe 'retry' do

    before(:each) do
      Typhoeus::Hydra.allow_net_connect = true
      @hydra = Typhoeus::Hydra.new :max_concurrency => 1
      @hydra.enable_memoization

      # make sure the flaky url is initially flaky
      @flaky_prefix = "http://localhost:3000/flaky"
      Typhoeus::Request.get("#{@flaky_prefix}/set?codes=503,200,503,200,503")
    end

    after(:each) do
      @hydra.run
    end

    describe 'server sanity check' do
      describe '/flaky' do
        it "should return 503 and then 200 for too successive GETs" do
          response = Typhoeus::Request.get("#{@flaky_prefix}?sanity-server-flip", :retry => false)
          response.code.should == 503

          response = Typhoeus::Request.get("#{@flaky_prefix}?sanity-server-flip", :retry => false)
          response.code.should == 200
        end

        it "it should return 503 multiple times if needed" do
          Typhoeus::Request.get("#{@flaky_prefix}/set?codes=503,503,200")

          response = Typhoeus::Request.get("#{@flaky_prefix}?sanity-server-list", :retry => false)
          response.code.should == 503

          response = Typhoeus::Request.get("#{@flaky_prefix}?sanity-server-list", :retry => false)
          response.code.should == 503

          response = Typhoeus::Request.get("#{@flaky_prefix}?sanity-server-list", :retry => false)
          response.code.should == 200
        end
      end
    end

    describe 'single request' do
      [:enable_memoization, :disable_memoization].each do |memoization_state|
        retryable_methods.each do |method|
          [503, 504].each do |code|
            it "of type #{method} with #{code} should retry request" do
              Typhoeus::Request.get("#{@flaky_prefix}/set?codes=#{code},200")
              request = Typhoeus::Request.new("#{@flaky_prefix}?single-#{code}-success", :method => method)
              @hydra.queue request
              @hydra.run

              request.response.code.should == 200
            end

            it "should result in exception with multiple #{method} yielding #{code} responses" do
              Typhoeus::Request.send(method, "#{@flaky_prefix}/set?codes=#{code},#{code},200")

              request = Typhoeus::Request.new("#{@flaky_prefix}?#{code}-multiple-times-fails", :method => method)
              @hydra.queue request

              @hydra.run

              request.response.code.should == code
            end
          end
        end
      end

      # TODO: check that 503 is not cached
      # TODO: check there is no retry on POST
      # TODO: maybe check that there is log output
    end

    describe 'two requests to the same URL with seperate callbacks' do
      [:enable_memoization, :disable_memoization].each do |memoization_state|
        retryable_methods.each do |method|
          [503, 504].each do |code|
            it "#{method} with a single #{code} should be retried (#{memoization_state})" do
              @hydra.send(memoization_state)
              callback_count = 0
              request1 = Typhoeus::Request.new("#{@flaky_prefix}?multi-request", :method => method)
              request1.on_complete { callback_count += 1 }
              request2 = Typhoeus::Request.new("#{@flaky_prefix}?multi-request", :method => method)
              request2.on_complete { callback_count += 1 }
              @hydra.queue request1
              @hydra.queue request2
              @hydra.run
              callback_count.should == 2
              request1.response.code.should == 200
              request2.response.code.should == 200
            end
          end
        end
      end
    end

    describe 'non GET requests with 503 and 504 response codes' do
      [:enable_memoization, :disable_memoization].each do |memoization_state|
        oneshot_methods.each do |method|
          [503, 504].each do |code|
            it "#{method} with #{code} response should not be retried (#{memoization_state})" do
              @hydra.send(memoization_state)
              Typhoeus::Request.get("#{@flaky_prefix}/set?codes=#{code},200")
              request = Typhoeus::Request.new("#{@flaky_prefix}?multi-#{code}-request",
                                              :method => method,
                                              :body => '[1, 2, 3]')
              @hydra.queue request

              @hydra.run

              request.response.code.should == code
            end
          end
        end
      end
    end
  end
end


