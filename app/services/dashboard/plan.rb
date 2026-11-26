module Dashboard
  # "What are you working on today?": the things the player is working on this commit, then one empty line to add the next (never
  # more than one empty line; when a line is filled in the page adds another), and, after a ship was sent back, what the reviewer
  # asked for. The items live on the active project (Project#todos). Without a project there is nothing to attach them to, so
  # the lines are not offered.
  class Plan
    Item = Data.define(:slot, :body, :done)
    View = Data.define(:items, :editable, :reviewer_note, :limit)

    def self.for(presenter) = new(presenter).view

    def initialize(presenter)
      @project = presenter.project
    end

    def view
      View.new(items: lines, editable: !@project.nil?, reviewer_note: reviewer_note, limit: Project::TODOS_MAX)
    end

    private

    # The saved items in order, then one empty line (unless the list is full).
    def lines
      saved = Array(@project&.todos).first(Project::TODOS_MAX).each_with_index.map do |entry, index|
        Item.new(slot: index + 1, body: entry["body"].to_s, done: entry["done"] == true)
      end
      saved << Item.new(slot: saved.size + 1, body: "", done: false) if saved.size < Project::TODOS_MAX
      saved
    end

    # Only while the latest ship is the one that was sent back; once the player ships again the note is old news.
    def reviewer_note
      ship = @project&.ship
      ship.reason if ship&.status == "rejected" && ship.reason.present?
    end
  end
end
