require "test_helper"

class DevSimulatorTest < ActiveSupport::TestCase
  test "which database hosts count as local" do
    [ nil, "", "localhost", "LOCALHOST", "127.0.0.1", "::1", "/var/run/postgresql", "/tmp" ].each do |host|
      assert DevSimulator.local_database?(host, hostaddr: nil, service: nil), host.inspect
    end
    [ "db.example.com", "10.0.0.5", "192.168.1.20", "postgres", "localhost.example.com", "127.0.0.1.evil.com", "prod-db.internal" ].each do |host|
      assert_not DevSimulator.local_database?(host, hostaddr: nil, service: nil), host
    end
  end

  test "a numeric address or a connection service can make a blank or local host remote" do
    assert DevSimulator.local_database?("localhost", hostaddr: "127.0.0.1", service: nil)
    assert DevSimulator.local_database?("", hostaddr: "::1", service: nil)
    assert DevSimulator.local_database?("localhost", hostaddr: nil, service: "prod"), "an explicit host wins over a service"
    [ [ "", "10.1.2.3", nil ], [ "localhost", "10.1.2.3", nil ], [ nil, "192.168.1.20", nil ], [ "", nil, "shared" ], [ nil, nil, "shared" ] ].each do |host, hostaddr, service|
      assert_not DevSimulator.local_database?(host, hostaddr: hostaddr, service: service), [ host, hostaddr, service ].inspect
    end
  end

  test "players are the users whose id starts with sim! and nobody else" do
    now = Time.current
    User.insert_all!([ "sim!1", "sim!99", "ident!sim!1", "sim", "simx", "SIM!2" ].map { |uid| { hca_uid: uid, signed_up_on: now.to_date, created_at: now, updated_at: now } })

    assert_equal %w[sim!1 sim!99], DevSimulator.players.order(:hca_uid).pluck(:hca_uid)
  end
end
