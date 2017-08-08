class AddEmployeeTable < ActiveRecord::Migration[5.0]
  create_table :employee_invitations do |t|
    t.string :invited_by
    t.string :email
    t.string :name
  end
end
