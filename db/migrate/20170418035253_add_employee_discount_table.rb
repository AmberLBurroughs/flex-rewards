class AddEmployeeDiscountTable < ActiveRecord::Migration[5.0]
  create_table :employee_discounts do |t|
    t.string  :code
    t.string  :email
    t.string  :first_name
    t.string  :last_name
    t.boolean :klaviyo_synced
  end
end
