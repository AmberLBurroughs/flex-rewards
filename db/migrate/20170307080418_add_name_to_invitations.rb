class AddNameToInvitations < ActiveRecord::Migration[5.0]
  def change
    change_table :invitations do |t|
      t.column :name, :string
    end
  end
end
