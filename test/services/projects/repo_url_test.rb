require "test_helper"

class Projects::RepoUrlTest < ActiveSupport::TestCase
  test "different spellings of one repo normalise to the same URL" do
    [ "https://github.com/octo/cat", "http://github.com/octo/cat", "HTTPS://GITHUB.COM/Octo/Cat", "https://www.github.com/octo/cat",
      "https://github.com/octo/cat/", "https://github.com/octo/cat.git", "https://github.com/octo/cat.git/", "  https://github.com/octo/cat\n",
      "http://www.GitHub.com/OCTO/cat.git//" ].each do |spelling|
      assert_equal "https://github.com/octo/cat", Projects::RepoUrl.normalize(spelling), spelling
    end
  end

  test "anything that is not a plain GitHub repo URL is nil" do
    [ nil, "", "   ", "github.com/octo/cat", "https://gitlab.com/octo/cat", "https://github.com/octo", "https://github.com/octo/",
      "https://github.com/octo/cat/issues", "https://github.com/octo/cat/tree/main", "https://github.com/octo/cat?tab=readme",
      "https://github.com/octo/cat#readme", "git@github.com:octo/cat.git", "ssh://git@github.com/octo/cat.git",
      "https://github.com.evil.example/octo/cat", "https://evil.example/https://github.com/octo/cat", "https://github.com/octo/..",
      "https://github.com/octo/cat dog", "https://user@github.com/octo/cat", "https://github.com:8080/octo/cat",
      "https://github.com/#{'a' * 300}/cat" ].each do |bad|
      assert_nil Projects::RepoUrl.normalize(bad), bad.inspect
    end
  end

  test "same? is true only for the same repo and never for two blanks" do
    assert Projects::RepoUrl.same?("https://github.com/Octo/Cat.git", "http://www.github.com/octo/cat/")
    assert_not Projects::RepoUrl.same?("https://github.com/octo/cat", "https://github.com/octo/cats")
    assert_not Projects::RepoUrl.same?("https://github.com/octo/cat", "https://github.com/other/cat")
    assert_not Projects::RepoUrl.same?(nil, nil)
    assert_not Projects::RepoUrl.same?("nope", "nope")
  end
end
